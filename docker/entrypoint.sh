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
  pkill openvpn 2>/dev/null
  sleep 1
  openvpn --config "$OVPN_FILE" \
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

# apply_killswitch: default-deny firewall. Design, in order of importance:
#   - traffic may only leave through tun0 (the tunnel), the loopback, or to
#     the LAN on the RPC port - never directly through eth0;
#   - the VPN server itself must stay reachable, so a broken tunnel can be
#     re-established without lifting the kill switch;
#   - DNS must stay available because OpenVPN re-resolves the server on
#     reconnection: DNS queries are the only packets allowed out of eth0,
#     and answers to anything we sent are accepted back (state rule);
#   - the same denial is applied to IPv6, with a sysctl disabling IPv6
#     entirely as defense in depth: the tunnel is IPv4-only and some hosts
#     lack the ip6_tables kernel module.
apply_killswitch() {
  echo "[rkz-vpn] INFO: applying kill switch (IPv4 + IPv6)..."

  VPN_REMOTE_LINE=$(grep -E '^remote ' "$OVPN_FILE" | head -1)
  VPN_REMOTE_IP=$(echo "$VPN_REMOTE_LINE" | awk '{print $2}')
  VPN_REMOTE_PORT=$(echo "$VPN_REMOTE_LINE" | awk '{print $3}')
  [ -z "$VPN_REMOTE_PORT" ] && VPN_REMOTE_PORT="1194"
  # normalize udp4/tcp4/udp6/tcp6/tcp-client -> udp/tcp (the only values `iptables -p` accepts)
  VPN_PROTO=$(grep -E '^proto ' "$OVPN_FILE" | head -1 | awk '{print $2}' | sed -E 's/(udp|tcp).*/\1/')
  [ -z "$VPN_PROTO" ] && VPN_PROTO="udp"

  # --- IPv4 ---
  iptables -F
  iptables -P INPUT DROP
  iptables -P OUTPUT DROP
  iptables -P FORWARD DROP

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -A INPUT -i tun0 -j ACCEPT
  iptables -A OUTPUT -o tun0 -j ACCEPT

  # answers to connections we sent out (DNS replies and the like); without
  # this rule they would be dropped by the INPUT DROP policy
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # LAN: only the RPC port is accepted - peer traffic goes through tun0
  # exclusively, so nothing torrent-related is ever exposed on the LAN
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    iptables -A INPUT -s "$range" -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -d "$range" -p tcp --sport 9091 -j ACCEPT
  done

  if [ -n "$VPN_REMOTE_IP" ]; then
    iptables -A OUTPUT -p "$VPN_PROTO" -d "$VPN_REMOTE_IP" --dport "$VPN_REMOTE_PORT" -j ACCEPT
    iptables -A INPUT -p "$VPN_PROTO" -s "$VPN_REMOTE_IP" --sport "$VPN_REMOTE_PORT" -j ACCEPT
  fi

  # outgoing DNS: required for reconnection (OpenVPN re-resolves the VPN
  # server) and for the public-IP check. DNS queries are the only packets
  # that ever leave outside the tunnel - never torrent traffic.
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  # --- IPv6: the tunnel is IPv4-only, so rather than routing v6 through it
  #     we deny all IPv6 egress; loopback and link-local/ULA stay open. ---
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F 2>/dev/null
    ip6tables -P INPUT DROP 2>/dev/null
    ip6tables -P OUTPUT DROP 2>/dev/null
    ip6tables -P FORWARD DROP 2>/dev/null
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    for range6 in fc00::/7 fe80::/10; do
      ip6tables -A INPUT -s "$range6" -j ACCEPT 2>/dev/null
      ip6tables -A OUTPUT -d "$range6" -j ACCEPT 2>/dev/null
    done
    echo "[rkz-vpn] OK: ip6tables applied (all IPv6 egress denied except loopback and link-local/ULA)."
  else
    echo "[rkz-vpn] WARN: ip6tables unavailable on this host (kernel module missing?)."
  fi

  echo "[rkz-vpn] OK: kill switch active."
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
      FETCHED_IP=$(wget -qO- --timeout=5 https://ifconfig.me 2>/dev/null)
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
reconnect() {
  write_status "false" "reconnecting..."
  until [ "$STOPPING" = "1" ] || start_vpn; do
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
  apply_killswitch
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
#    shell (PID 1) stays in charge of the watchdog below.
# -----------------------------------------------------------------------------
su-exec rakiz:rakiz transmission-daemon --foreground --config-dir /config &
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
