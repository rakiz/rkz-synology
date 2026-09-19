#!/bin/sh
# =============================================================================
# rkz-vpn entrypoint
#
# What this container does, in order:
#   1. Brings up the OpenVPN tunnel from a provider-supplied .ovpn file
#      (mounted in /openvpn - no VPN provider is hard-coded anywhere).
#   2. Installs a firewall kill switch: without the tunnel, nothing gets
#      out (except LAN RPC and DNS), so a dropped tunnel never leaks traffic.
#   3. Runs Transmission as a non-root user.
#   4. Watches the tunnel forever and repairs it on its own when it dies -
#      including "zombie" tunnels that exist but carry no traffic.
#
# Everything is logged to stdout: Container Manager (or `docker logs`) is
# the single place to look when something is wrong.
# =============================================================================

CREDS_FILE="/openvpn/credentials.txt"
OPENVPN_LOG="/var/log/openvpn.log"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"    # seconds between real watchdog checks
ZOMBIE_THRESHOLD="${ZOMBIE_THRESHOLD:-3}" # consecutive failed probes before forcing a reconnect (0 = off)
RETRY_DELAY_MAX="${RETRY_DELAY_MAX:-60}"  # cap of the exponential backoff between reconnect attempts
TRANSMISSION_PID=""
STOPPING=0
CURRENT_IP=""
PREV_STATE=""
STATUS_TICKS=0
ZOMBIE_COUNT=0
RETRY_DELAY=10
LOG_OFFSET=0

# -----------------------------------------------------------------------------
# 0. Locate the .ovpn file: $OVPN_FILE if set, otherwise the first *.ovpn
#    found in /openvpn. The provider is simply whatever file is mounted:
#    nothing in this script is tied to a specific one.
# -----------------------------------------------------------------------------
if [ -z "$OVPN_FILE" ]; then
  for f in /openvpn/*.ovpn; do
    [ -f "$f" ] && OVPN_FILE="$f" && break
  done
fi

if [ -z "$OVPN_FILE" ] || [ ! -f "$OVPN_FILE" ]; then
  echo "[rkz-vpn] ERROR: no .ovpn file found in /openvpn."
  echo "[rkz-vpn] Drop a .ovpn file in the volume mounted on /openvpn,"
  echo "[rkz-vpn] or set the OVPN_FILE environment variable explicitly."
  exit 1
fi
if [ ! -f "$CREDS_FILE" ]; then
  echo "[rkz-vpn] ERROR: $CREDS_FILE not found."
  exit 1
fi
if [ ! -f "/config/settings.json" ]; then
  echo "[rkz-vpn] ERROR: /config/settings.json not found."
  echo "[rkz-vpn] The Transmission settings are provided by YOU in the /config volume"
  echo "[rkz-vpn] (nothing is baked into the image). Fix:"
  echo "[rkz-vpn]   cp configuration/settings.json.example <your /config volume>/settings.json"
  echo "[rkz-vpn]   then set rpc-username / rpc-password in it (see configuration/README.md)."
  exit 1
fi
echo "[rkz-vpn] INFO: config file in use: $OVPN_FILE"

# -----------------------------------------------------------------------------
# Signal handling: the trap only raises a flag. Every loop in this script
# checks it at least once per second, so `docker stop` is honored quickly
# and Transmission still gets the time to flush its state cleanly.
# -----------------------------------------------------------------------------
# called via `trap` on TERM/INT - shellcheck can't see that, hence SC2317
# shellcheck disable=SC2317
term_handler() {
  echo "[rkz-vpn] $(date '+%F %T') Stop requested."
  STOPPING=1
}
trap term_handler TERM INT

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------
# start_vpn: launch OpenVPN as a daemon, then wait up to 30s for tun0 to
# appear. tun0 existing means the session was negotiated; if it never shows
# up, the [openvpn] lines streamed to stdout tell exactly why (bad
# credentials, DNS, unreachable server...).
start_vpn() {
  echo "[rkz-vpn] $(date '+%F %T') INFO: starting OpenVPN tunnel..."
  # SIGTERM, not SIGKILL: OpenVPN deletes its pushed routes on a clean exit.
  # Killed hard, the redirect-gateway routes survive and the next DNS query
  # is blackholed into a dead tun0 - a self-inflicted reconnection deadlock.
  pkill -TERM openvpn 2>/dev/null
  for _k in 1 2 3 4 5 6 7 8 9 10; do
    pgrep openvpn >/dev/null 2>&1 || break
    sleep 1
  done
  pgrep openvpn >/dev/null 2>&1 && pkill -KILL openvpn 2>/dev/null
  sleep 1
  # provider .ovpn files reference their certs relatively (ca ca.crt) - run
  # from the .ovpn's own folder so they always resolve, whatever the provider
  openvpn --cd "$(dirname "$OVPN_FILE")" \
          --config "$OVPN_FILE" \
          --auth-user-pass "$CREDS_FILE" \
          --daemon \
          --log "$OPENVPN_LOG"

  for i in $(seq 1 30); do
    [ "$STOPPING" = "1" ] && return 1
    if ip addr show tun0 >/dev/null 2>&1; then
      echo "[rkz-vpn] OK: tunnel is up after ${i}s."
      return 0
    fi
    sleep 1
  done
  echo "[rkz-vpn] ERROR: tunnel never came up. Last OpenVPN log lines:"
  tail -n 20 "$OPENVPN_LOG" 2>/dev/null
  return 1
}

# -----------------------------------------------------------------------------
# Kill switch.
#
# Design:
#   1. STATIC: installed once, before OpenVPN is ever started, never rebuilt -
#      there is no instant where the policy is DROP without its allow rules.
#   2. TRANSPORT-BASED, not address-based: "udp/443 out of the physical
#      interface", not "udp/443 to <server IP>" - providers hand out
#      round-robin pools spanning several /24s; any address allow-list goes
#      stale the moment the client reconnects elsewhere in the pool.
#   3. Each hole is closed with `-m owner --uid-owner 0`: OpenVPN runs as
#      root, Transmission as uid 1000 - Transmission structurally cannot use
#      them. Nothing torrent-related ever leaves outside tun+.
#   4. STATELESS on the critical path (--sport instead of -m state) and
#      applied ATOMICALLY with iptables-restore.
#   5. The nft backend is neutralized first: nft and legacy are two
#      INDEPENDENT hook sets in the same network namespace - a packet must
#      be accepted by BOTH, and on old kernels the nft backend keeps
#      default-DROP policies it could never pair with rules.
# -----------------------------------------------------------------------------

KS_LAN_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
KS_DNS_SERVERS="1.1.1.1 9.9.9.9"
IPT=""
IPT6=""
IPT_RESTORE=""
IPT6_RESTORE=""
WAN_IF="eth0"
OWNER_MATCH=""
RPC_PORT="9091"

select_firewall_tools() {
  IPT=$(command -v iptables-legacy || command -v iptables)
  IPT6=$(command -v ip6tables-legacy || command -v ip6tables)
  IPT_RESTORE=$(command -v iptables-legacy-restore || command -v iptables-restore)
  IPT6_RESTORE=$(command -v ip6tables-legacy-restore || command -v ip6tables-restore)

  # never drive one backend with the other's restore tool
  case "$IPT" in
    *-legacy) case "$IPT_RESTORE" in *-legacy-restore) ;; *) IPT_RESTORE="" ;; esac ;;
  esac
  case "$IPT6" in
    *-legacy) case "$IPT6_RESTORE" in *-legacy-restore) ;; *) IPT6_RESTORE="" ;; esac ;;
  esac

  case "$IPT" in
    *-legacy) echo "[rkz-vpn] INFO: firewall backend: legacy ($IPT)." ;;
    *) echo "[rkz-vpn] WARN: iptables-legacy missing, falling back to $IPT."
       echo "[rkz-vpn] WARN: on old kernels the nft backend rejects -p/-m rules." ;;
  esac
}

# nft and legacy are two independent netfilter hook sets sharing one netns:
# a leftover default-DROP nft chain vetoes every legacy ACCEPT. Reset it.
neutralize_nft_backend() {
  nft_v4=$(command -v iptables-nft 2>/dev/null)
  nft_v6=$(command -v ip6tables-nft 2>/dev/null)
  # if the -nft aliases are absent but -legacy exists, the bare names ARE nft
  if [ -z "$nft_v4" ] && command -v iptables-legacy >/dev/null 2>&1; then
    nft_v4=$(command -v iptables 2>/dev/null)
    nft_v6=$(command -v ip6tables 2>/dev/null)
  fi

  for b in $nft_v4 $nft_v6; do
    # -P and -F carry no xtables extension: they are the only two operations
    # that still work when nft_compat cannot load xt_tcpudp/xt_state
    for c in INPUT OUTPUT FORWARD; do
      "$b" -P "$c" ACCEPT 2>/dev/null
    done
    "$b" -F 2>/dev/null
    "$b" -X 2>/dev/null

    leftover=$("$b" -S 2>/dev/null | grep -v -e '^-P [A-Z]* ACCEPT$' -e '^$')
    if [ -n "$leftover" ]; then
      echo "[rkz-vpn] WARN: the nft backend ($b) still enforces rules:"
      echo "$leftover" | sed 's/^/[rkz-vpn]   /'
      echo "[rkz-vpn] WARN: they apply IN ADDITION to the legacy ones and can"
      echo "[rkz-vpn] WARN: veto them. Recreate the container to get a clean"
      echo "[rkz-vpn] WARN: network namespace: 'docker compose down && up -d'"
      echo "[rkz-vpn] WARN: ('docker restart' reuses the same netns)."
    else
      echo "[rkz-vpn] OK: nft backend neutralized ($b)."
    fi
  done
}

# The physical egress interface, read BEFORE OpenVPN touches the routing
# table (while the default route still points at the docker gateway).
detect_wan_if() {
  WAN_IF=$(ip route show 2>/dev/null \
           | awk '/^default/ {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i+1); exit}}')
  [ -z "$WAN_IF" ] && WAN_IF="eth0"
  echo "[rkz-vpn] INFO: physical egress interface: $WAN_IF"
}

# The RPC port is the user's, in the user's settings.json - never assumed.
detect_rpc_port() {
  RPC_PORT=$(sed -n 's/.*"rpc-port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
             /config/settings.json 2>/dev/null | head -1)
  [ -z "$RPC_PORT" ] && RPC_PORT="9091"
  echo "[rkz-vpn] INFO: RPC port opened to the LAN: $RPC_PORT"
}

# iptables-restore commits the whole table in ONE transaction: a single
# unsupported match makes the ENTIRE ruleset fail. So xt_owner is probed
# before it is ever written into the payload.
probe_owner_match() {
  if $IPT -A OUTPUT -o "$WAN_IF" -p udp --dport 1 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null; then
    $IPT -D OUTPUT -o "$WAN_IF" -p udp --dport 1 -m owner --uid-owner 0 -j ACCEPT 2>/dev/null
    OWNER_MATCH="-m owner --uid-owner 0"
    echo "[rkz-vpn] OK: xt_owner available - the VPN and DNS holes are"
    echo "[rkz-vpn]     restricted to uid 0 (OpenVPN); Transmission (uid 1000)"
    echo "[rkz-vpn]     structurally cannot use them."
  else
    OWNER_MATCH=""
    echo "[rkz-vpn] WARN: xt_owner unavailable on this kernel."
    echo "[rkz-vpn] WARN: the udp VPN port and DNS stay open to every uid in"
    echo "[rkz-vpn] WARN: the container. Everything else is still denied."
  fi
}

# "<proto> <port>" for every `remote` line of the .ovpn, deduplicated.
# We allow the VPN TRANSPORT, never a server address: provider pools are
# round-robin across several /24s, so any address allow-list is stale as
# soon as the client reconnects elsewhere - a stale allow-list deadlocks
# reconnection.
vpn_transport_rules() {
  default_proto=$(grep -Ei '^[[:space:]]*proto[[:space:]]' "$OVPN_FILE" 2>/dev/null \
                  | head -1 | awk '{print tolower($2)}' | sed -E 's/^(udp|tcp).*/\1/')
  case "$default_proto" in udp|tcp) ;; *) default_proto="udp" ;; esac

  default_port=$(grep -Ei '^[[:space:]]*port[[:space:]]' "$OVPN_FILE" 2>/dev/null \
                 | head -1 | awk '{print $2}')
  case "$default_port" in ''|*[!0-9]*) default_port="1194" ;; esac

  grep -Ei '^[[:space:]]*remote[[:space:]]' "$OVPN_FILE" 2>/dev/null \
  | while read -r _kw _host rport rproto _rest; do
      case "$rport" in ''|*[!0-9]*) rport="$default_port" ;; esac
      case "$(echo "$rproto" | tr '[:upper:]' '[:lower:]')" in
        udp*) rproto="udp" ;;
        tcp*) rproto="tcp" ;;
        *)    rproto="$default_proto" ;;
      esac
      echo "$rproto $rport"
    done | sort -u
}

emit_ruleset_v4() {
  echo "*filter"
  echo ":INPUT DROP [0:0]"
  echo ":FORWARD DROP [0:0]"
  echo ":OUTPUT DROP [0:0]"

  # --- loopback ---
  echo "-A INPUT -i lo -j ACCEPT"
  echo "-A OUTPUT -o lo -j ACCEPT"

  # --- the tunnel: the only unrestricted path in or out. tun+ (not tun0)
  #     so the rules are valid before the device exists and survive a
  #     device rename. Everything Transmission does goes through here. ---
  echo "-A INPUT -i tun+ -j ACCEPT"
  echo "-A OUTPUT -o tun+ -j ACCEPT"

  # --- VPN transport out of the physical interface. Stateless on purpose
  #     (--sport on the way back instead of -m state): no dependency on
  #     nf_conntrack/xt_state being loadable on this kernel. ---
  vpn_transport_rules | while read -r kp kport; do
    echo "-A OUTPUT -o $WAN_IF -p $kp --dport $kport $OWNER_MATCH -j ACCEPT"
    echo "-A INPUT -i $WAN_IF -p $kp --sport $kport -j ACCEPT"
  done

  # --- DNS, only to the two resolvers we forced into resolv.conf, only for
  #     uid 0. Needed solely so OpenVPN can re-resolve its remote while the
  #     tunnel is down; when the tunnel is up these queries take tun+ and
  #     never match these rules. Transmission can never DNS-leak here. ---
  for ksns in $KS_DNS_SERVERS; do
    echo "-A OUTPUT -o $WAN_IF -d $ksns -p udp --dport 53 $OWNER_MATCH -j ACCEPT"
    echo "-A OUTPUT -o $WAN_IF -d $ksns -p tcp --dport 53 $OWNER_MATCH -j ACCEPT"
    echo "-A INPUT -i $WAN_IF -s $ksns -p udp --sport 53 -j ACCEPT"
    echo "-A INPUT -i $WAN_IF -s $ksns -p tcp --sport 53 -j ACCEPT"
  done

  # --- LAN: the RPC port only, and only from RFC1918. Peer traffic is
  #     tun+-only, so nothing torrent-related is ever exposed on the LAN. ---
  for ksr in $KS_LAN_RANGES; do
    echo "-A INPUT -i $WAN_IF -s $ksr -p tcp --dport $RPC_PORT -j ACCEPT"
    echo "-A OUTPUT -o $WAN_IF -d $ksr -p tcp --sport $RPC_PORT -j ACCEPT"
  done

  echo "COMMIT"
}

emit_ruleset_v6() {
  echo "*filter"
  echo ":INPUT DROP [0:0]"
  echo ":FORWARD DROP [0:0]"
  echo ":OUTPUT DROP [0:0]"
  echo "-A INPUT -i lo -j ACCEPT"
  echo "-A OUTPUT -o lo -j ACCEPT"
  for ksr6 in fe80::/10 fc00::/7; do
    echo "-A INPUT -s $ksr6 -j ACCEPT"
    echo "-A OUTPUT -d $ksr6 -j ACCEPT"
  done
  echo "COMMIT"
}

# Ordered fallback for hosts without iptables-legacy-restore: policies are
# left ACCEPT while the rules go in and only flipped to DROP at the very
# end, so the box is never default-deny without its allow rules.
apply_ruleset_sequential() {
  _bin="$1"
  _emit="$2"
  for c in INPUT OUTPUT FORWARD; do
    "$_bin" -P "$c" ACCEPT 2>/dev/null
  done
  "$_bin" -F 2>/dev/null
  "$_emit" | grep '^-A ' | while read -r line; do
    # shellcheck disable=SC2086
    $_bin $line 2>/dev/null || echo "[rkz-vpn] WARN: rule rejected: $_bin $line"
  done
  for c in FORWARD INPUT OUTPUT; do
    "$_bin" -P "$c" DROP 2>/dev/null
  done
}

apply_killswitch() {
  echo "[rkz-vpn] INFO: applying kill switch (IPv4 + IPv6)..."

  select_firewall_tools
  neutralize_nft_backend
  detect_wan_if
  detect_rpc_port
  probe_owner_match

  # --- IPv4 ---
  if [ -n "$IPT_RESTORE" ] && emit_ruleset_v4 | $IPT_RESTORE 2>/dev/null; then
    echo "[rkz-vpn] OK: IPv4 ruleset committed atomically ($IPT_RESTORE)."
  else
    echo "[rkz-vpn] WARN: atomic restore unavailable or refused, applying"
    echo "[rkz-vpn] WARN: the rules one by one."
    apply_ruleset_sequential "$IPT" emit_ruleset_v4
  fi

  # --- IPv6 ---
  if [ -n "$IPT6" ]; then
    if [ -n "$IPT6_RESTORE" ] && emit_ruleset_v6 | $IPT6_RESTORE 2>/dev/null; then
      echo "[rkz-vpn] OK: all IPv6 egress denied (loopback and link-local/ULA aside)."
    else
      apply_ruleset_sequential "$IPT6" emit_ruleset_v6
      echo "[rkz-vpn] OK: IPv6 denial applied rule by rule."
    fi
  else
    echo "[rkz-vpn] WARN: ip6tables unavailable (kernel module missing?);"
    echo "[rkz-vpn] WARN: relying on the disable_ipv6 sysctl alone."
  fi

  verify_killswitch
}

# Printed once at startup: the effective ruleset in `docker logs` is the
# difference between debugging this and guessing at it.
verify_killswitch() {
  ks_ok=1

  for c in INPUT OUTPUT FORWARD; do
    $IPT -S "$c" 2>/dev/null | grep -q -- "-P $c DROP" || {
      echo "[rkz-vpn] ERROR: IPv4 $c policy is NOT DROP - the kill switch is not sealed."
      ks_ok=0
    }
  done
  $IPT -S OUTPUT 2>/dev/null | grep -q -- '-o tun+' || {
    echo "[rkz-vpn] ERROR: no tun+ egress rule - the tunnel would carry nothing."
    ks_ok=0
  }
  vpn_transport_rules | while read -r kp kport; do
    $IPT -S OUTPUT 2>/dev/null | grep -q -- "--dport $kport" || \
      echo "[rkz-vpn] ERROR: no $kp/$kport egress rule - OpenVPN cannot reach its server."
  done

  echo "[rkz-vpn] INFO: effective IPv4 ruleset:"
  $IPT -S 2>/dev/null | sed 's/^/[rkz-vpn]   /'

  if [ "$ks_ok" = "1" ]; then
    echo "[rkz-vpn] OK: kill switch active (default deny; out = tun+, lo,"
    echo "[rkz-vpn]     VPN transport, DNS to $KS_DNS_SERVERS, RPC $RPC_PORT to the LAN)."
  else
    echo "[rkz-vpn] ERROR: kill switch INCOMPLETE - see the errors above."
  fi
}

# Called when a connection attempt fails: packet counters tell whether the
# VPN transport rule was matched at all (nonzero = the legacy chain let the
# packet through and something else dropped it, e.g. a leftover nft chain;
# zero = the packet never matched, i.e. wrong interface/proto/port).
dump_firewall_counters() {
  echo "[rkz-vpn] INFO: OUTPUT chain counters (packet-level evidence):"
  $IPT -L OUTPUT -v -n --line-numbers 2>/dev/null | sed 's/^/[rkz-vpn]   /'
}

disable_ipv6_sysctl() {
  # Defense in depth: if this works, IPv6 is off at the kernel level inside
  # the container even when the host lacks the ip6_tables module (common on
  # Synology DSM - the same reason WireGuard often can't be used there).
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 \
    && echo "[rkz-vpn] OK: IPv6 disabled via sysctl." \
    || echo "[rkz-vpn] WARN: IPv6 sysctl not applicable here (fine if ip6tables worked)."
}

tunnel_is_healthy() {
  # both conditions must hold: a defunct openvpn process still matches pgrep
  # but then tun0 is gone, and tun0 without its process dies on the next poll
  ip addr show tun0 >/dev/null 2>&1 && pgrep openvpn >/dev/null 2>&1
}

write_status() {
  state_label="$1"      # "true" | "false" (anything else is treated as "false")
  ip_label="$2"
  case "$state_label" in true) ;; *) state_label="false" ;; esac

  # The public IP is refreshed on first connect, after each reconnect (the
  # exit IP may change) and once an hour only - staying polite with the
  # public IP-echo service, and so the file stays a trustworthy check.
  if [ "$state_label" = "true" ] && [ -z "$ip_label" ]; then
    if [ -z "$CURRENT_IP" ] || [ "$PREV_STATE" != "true" ] || [ "$STATUS_TICKS" -ge 120 ]; then
      FETCHED_IP=$(wget -qO- --timeout=5 https://ifconfig.me/ip 2>/dev/null)
      if [ -n "$FETCHED_IP" ] || [ -z "$CURRENT_IP" ]; then
        CURRENT_IP="$FETCHED_IP"
      fi
      STATUS_TICKS=0
    else
      STATUS_TICKS=$((STATUS_TICKS + 1))
    fi
    ip_label="$CURRENT_IP"
    [ -z "$ip_label" ] && ip_label="unavailable"
  fi
  PREV_STATE="$state_label"

  # written into the /config volume: readable from the NAS file browser,
  # no docker skills needed to know whether the VPN is doing its job
  ip_label=$(echo "$ip_label" | tr -d '"\n')
  cat > /config/vpn-status.json <<EOF
{
  "last_check": "$(date -Iseconds)",
  "tunnel_up": $state_label,
  "public_ip": "$ip_label"
}
EOF
}

graceful_shutdown() {
  # give Transmission up to 20s to flush settings.json/.resume files, then
  # SIGKILL; OpenVPN is killed right away - at shutdown the kill switch no
  # longer matters
  echo "[rkz-vpn] $(date '+%F %T') INFO: stopping Transmission (flushing settings/resume)..."
  [ -n "$STREAMER_PID" ] && kill "$STREAMER_PID" 2>/dev/null
  if [ -n "$TRANSMISSION_PID" ]; then
    kill -TERM "$TRANSMISSION_PID" 2>/dev/null
    for i in $(seq 1 20); do
      kill -0 "$TRANSMISSION_PID" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$TRANSMISSION_PID" 2>/dev/null && kill -9 "$TRANSMISSION_PID" 2>/dev/null
  fi
  pkill openvpn 2>/dev/null
  echo "[rkz-vpn] OK: shutdown complete."
  exit 0
}

# sleep in 1s slices so the stop flag is honored within a second even in
# the middle of a backoff delay
sleep_interruptible() {
  t=0
  while [ "$t" -lt "$1" ]; do
    [ "$STOPPING" = "1" ] && return 1
    sleep 1
    t=$((t + 1))
  done
  return 0
}

# reconnect: (re)establish the tunnel with exponential backoff (10s up to
# RETRY_DELAY_MAX). Returns 1 if a stop was requested while retrying,
# 0 otherwise.
#
# The kill switch is NOT reapplied here: it is static, installed once
# before the first connection, and interface-based - it needs no knowledge
# of the current session.
reconnect() {
  write_status "false" "reconnecting..."
  ks_attempts=0
  until [ "$STOPPING" = "1" ] || start_vpn; do
    ks_attempts=$((ks_attempts + 1))
    [ "$ks_attempts" = "3" ] && dump_firewall_counters
    echo "[rkz-vpn] INFO: reconnecting in ${RETRY_DELAY}s..."
    sleep_interruptible "$RETRY_DELAY"
    RETRY_DELAY=$((RETRY_DELAY * 2))
    [ "$RETRY_DELAY" -gt "$RETRY_DELAY_MAX" ] && RETRY_DELAY="$RETRY_DELAY_MAX"
  done
  if [ "$STOPPING" = "1" ]; then
    return 1
  fi
  RETRY_DELAY=10
  ZOMBIE_COUNT=0
  echo "[rkz-vpn] $(date '+%F %T') OK: tunnel restored."
}

# -----------------------------------------------------------------------------
# OpenVPN log forwarding: OpenVPN writes to a file, Container Manager reads
# stdout - stream every new log line to stdout in near real time so
# authentication failures, DNS problems and handshake errors are visible in
# `docker logs` without exec-ing into the container.
# -----------------------------------------------------------------------------
( while :; do
    [ -f "$OPENVPN_LOG" ] || { sleep 1; continue; }
    size=$(wc -c < "$OPENVPN_LOG" 2>/dev/null) || size=0
    if [ "$size" -gt "$LOG_OFFSET" ]; then
      tail -c +$((LOG_OFFSET + 1)) "$OPENVPN_LOG" 2>/dev/null | sed 's/^/[openvpn] /'
      LOG_OFFSET=$size
    elif [ "$size" -lt "$LOG_OFFSET" ]; then
      LOG_OFFSET=$size
    fi
    sleep 1
  done ) &
STREAMER_PID=$!

# -----------------------------------------------------------------------------
# 1. IPv6 off from the start, then first connection. Retry forever with
#    backoff: without a tunnel this container has nothing useful to do, and
#    at this point no torrent client is running yet (no leak possible).
# -----------------------------------------------------------------------------
disable_ipv6_sysctl

# DNS: use public resolvers, reached THROUGH the tunnel when it is up, and
# directly when it is down (the kill switch allows exactly that, for uid 0
# only). Host-provided resolvers (Docker's 127.0.0.11, LAN proxies) are
# unreachable as soon as the tunnel routes everything away.
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 9.9.9.9
EOF

# The /dev/net/tun node file is absent on some hosts (Synology ships the
# tun kernel module without the node): create it ourselves - the module
# itself is the real requirement, and NET_ADMIN grants us the mknod.
mkdir -p /dev/net
[ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200

# The kill switch goes up BEFORE the first connection attempt and is never
# touched again:
#   - installed before OpenVPN, there is no instant in the container's life
#     where traffic can leave unfiltered;
#   - never reapplied, there is no instant where the policy is DROP without
#     its allow rules - OpenVPN's `ping 5` keepalive survives because the
#     rules and the policy land together, atomically.
# WAN_IF is read here, while the default route still points at the docker
# gateway - OpenVPN has not touched the routing table yet.
apply_killswitch

reconnect || graceful_shutdown

# -----------------------------------------------------------------------------
# 2. Transmission configuration: user-provided in the /config volume
#    (checked at startup, fail fast) - nothing is seeded or overwritten
#    here. Non-recursive chown: top-level dirs only, never the whole
#    (possibly multi-TB) data tree.
# -----------------------------------------------------------------------------
mkdir -p /data/completed /data/incomplete /data/watch
chown rakiz:rakiz /config /data /data/completed /data/incomplete /data/watch 2>/dev/null

# -----------------------------------------------------------------------------
# 3. Start Transmission as the unprivileged user, in the background; this
#    shell (PID 1) stays in charge of the watchdog below. setpriv (not
#    su-exec) re-initializes the user's supplementary groups from /etc/group
#    - rakiz is a member of GID 101, which the NAS data ACLs allow.
# -----------------------------------------------------------------------------
setpriv --reuid 1000 --regid 1000 --init-groups transmission-daemon --foreground --config-dir /config &
TRANSMISSION_PID=$!
echo "[rkz-vpn] INFO: Transmission started (PID $TRANSMISSION_PID)."
write_status "true"

# -----------------------------------------------------------------------------
# 4. Watchdog loop: wake up every second (so a stop request is noticed fast)
#    but only run the real checks every CHECK_INTERVAL seconds. Two failure
#    modes are handled:
#      - the tunnel is plainly down (tun0 or the openvpn process is gone);
#      - the tunnel looks alive but carries no traffic ("zombie": the VPN
#        server stopped answering). Probed by pinging through tun0; after
#        ZOMBIE_THRESHOLD consecutive failures the tunnel is reconnected.
#        Set ZOMBIE_THRESHOLD=0 if your VPN provider blocks ICMP.
# -----------------------------------------------------------------------------
elapsed=0
while [ "$STOPPING" != "1" ]; do
  sleep 1
  elapsed=$((elapsed + 1))
  if [ "$elapsed" -lt "$CHECK_INTERVAL" ]; then
    continue
  fi
  elapsed=0

  if ! tunnel_is_healthy; then
    echo "[rkz-vpn] $(date '+%F %T') INFO: tunnel down detected, reconnecting..."
    reconnect || break
  elif [ "$ZOMBIE_THRESHOLD" -gt 0 ]; then
    if ping -c 1 -W 3 -I tun0 1.1.1.1 >/dev/null 2>&1; then
      ZOMBIE_COUNT=0
    else
      ZOMBIE_COUNT=$((ZOMBIE_COUNT + 1))
      echo "[rkz-vpn] $(date '+%F %T') WARN: tunnel is alive but carries no traffic ($ZOMBIE_COUNT/$ZOMBIE_THRESHOLD)..."
      if [ "$ZOMBIE_COUNT" -ge "$ZOMBIE_THRESHOLD" ]; then
        echo "[rkz-vpn] $(date '+%F %T') WARN: zombie tunnel detected, forcing reconnect..."
        ZOMBIE_COUNT=0
        reconnect || break
      fi
    fi
  fi

  write_status "true"

  if ! kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
    echo "[rkz-vpn] $(date '+%F %T') ERROR: Transmission exited unexpectedly."
    echo "[rkz-vpn] Exiting so Docker restarts the whole container cleanly."
    exit 1
  fi
done

graceful_shutdown
