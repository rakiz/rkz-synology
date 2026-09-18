#!/bin/sh
# =============================================================================
# rkz-vpn entrypoint
# - Monte le tunnel OpenVPN (fournisseur agnostique : auto-détecte le .ovpn
#   présent dans /openvpn, ou utilise $OVPN_FILE si fourni explicitement)
# - Applique un kill switch iptables + ip6tables (+ désactivation IPv6 en secours)
# - Démarre Transmission
# - Surveille le tunnel en continu, se reconnecte seul, et s'arrête proprement
# =============================================================================

CREDS_FILE="/openvpn/credentials.txt"
OPENVPN_LOG="/var/log/openvpn.log"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
TRANSMISSION_PID=""
STOPPING=0
CURRENT_IP=""
PREV_STATE=""
STATUS_TICKS=0
ZOMBIE_COUNT=0
ZOMBIE_THRESHOLD="${ZOMBIE_THRESHOLD:-3}"
RETRY_DELAY=10
RETRY_DELAY_MAX="${RETRY_DELAY_MAX:-60}"

# -----------------------------------------------------------------------------
# 0. Détection du fichier .ovpn : $OVPN_FILE si défini, sinon le seul .ovpn
#    trouvé dans /openvpn. Aucun nom de fournisseur codé en dur.
# -----------------------------------------------------------------------------
if [ -z "$OVPN_FILE" ]; then
  for f in /openvpn/*.ovpn; do
    [ -f "$f" ] && OVPN_FILE="$f" && break
  done
fi

if [ -z "$OVPN_FILE" ] || [ ! -f "$OVPN_FILE" ]; then
  echo "[rkz-vpn] ERREUR: aucun fichier .ovpn trouvé dans /openvpn."
  echo "[rkz-vpn] Dépose un fichier .ovpn dans le volume monté sur /openvpn,"
  echo "[rkz-vpn] ou fixe explicitement la variable d'env OVPN_FILE."
  exit 1
fi
if [ ! -f "$CREDS_FILE" ]; then
  echo "[rkz-vpn] ERREUR: $CREDS_FILE introuvable."
  exit 1
fi
echo "[rkz-vpn] Fichier de config utilisé : $OVPN_FILE"

# -----------------------------------------------------------------------------
# Signal handling : on positionne juste un flag, vérifié toutes les 1s dans
# les boucles (pas de sleep long qui retarderait la réaction).
# -----------------------------------------------------------------------------
term_handler() {
  echo "[rkz-vpn] $(date '+%F %T') Arrêt demandé."
  STOPPING=1
}
trap term_handler TERM INT

# -----------------------------------------------------------------------------
# Fonctions
# -----------------------------------------------------------------------------
start_vpn() {
  echo "[rkz-vpn] $(date '+%F %T') Démarrage du tunnel OpenVPN..."
  pkill openvpn 2>/dev/null
  sleep 1
  openvpn --config "$OVPN_FILE" \
          --auth-user-pass "$CREDS_FILE" \
          --daemon \
          --log "$OPENVPN_LOG"

  for i in $(seq 1 30); do
    [ "$STOPPING" = "1" ] && return 1
    if ip addr show tun0 >/dev/null 2>&1; then
      echo "[rkz-vpn] Tunnel actif après ${i}s."
      return 0
    fi
    sleep 1
  done
  echo "[rkz-vpn] Échec de montée du tunnel. Logs OpenVPN :"
  tail -n 20 "$OPENVPN_LOG" 2>/dev/null
  return 1
}

apply_killswitch() {
  echo "[rkz-vpn] Application du kill switch (IPv4 + IPv6)..."

  VPN_REMOTE_LINE=$(grep -E '^remote ' "$OVPN_FILE" | head -1)
  VPN_REMOTE_IP=$(echo "$VPN_REMOTE_LINE" | awk '{print $2}')
  VPN_REMOTE_PORT=$(echo "$VPN_REMOTE_LINE" | awk '{print $3}')
  [ -z "$VPN_REMOTE_PORT" ] && VPN_REMOTE_PORT="1194"
  # normalisation : udp4/tcp4/udp6/tcp6/tcp-client -> udp/tcp (seules valeurs valides pour `iptables -p`)
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

  # Réponses aux connexions sortantes autorisées (DNS, etc.) : sans ça, les
  # réponses DNS arrivant sur eth0 seraient jetées par la policy INPUT DROP.
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  # LAN : limité au RPC (le trafic pair-à-pair transite exclusivement par tun0)
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    iptables -A INPUT -s "$range" -p tcp --dport 9091 -j ACCEPT
    iptables -A OUTPUT -d "$range" -p tcp --sport 9091 -j ACCEPT
  done

  if [ -n "$VPN_REMOTE_IP" ]; then
    iptables -A OUTPUT -p "$VPN_PROTO" -d "$VPN_REMOTE_IP" --dport "$VPN_REMOTE_PORT" -j ACCEPT
    iptables -A INPUT -p "$VPN_PROTO" -s "$VPN_REMOTE_IP" --sport "$VPN_REMOTE_PORT" -j ACCEPT
  fi

  # DNS sortant : nécessaire à la reconnexion (OpenVPN re-résout le serveur
  # VPN) et au contrôle d'IP publique. Seules des requêtes DNS sortent hors
  # tunnel, jamais de trafic torrent.
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

  # --- IPv6 : le tunnel CyberGhost est IPv4 uniquement, donc on bloque tout
  #     IPv6 hors LAN plutôt que d'essayer de le faire transiter par tun0. ---
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
    echo "[rkz-vpn] ip6tables appliqué (tout IPv6 sortant bloqué, hors loopback et préfixes link-local/ULA)."
  else
    echo "[rkz-vpn] AVERTISSEMENT: ip6tables indisponible sur cet hôte (module kernel absent ?)."
  fi

  echo "[rkz-vpn] Kill switch actif."
}

disable_ipv6_sysctl() {
  # Défense en profondeur : si le sysctl passe, IPv6 est coupé au niveau
  # noyau du conteneur, indépendamment de ip6tables (utile si le module
  # ip6_tables n'est pas dispo sur l'hôte, cas fréquent sur Synology DSM).
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 \
    && echo "[rkz-vpn] IPv6 désactivé via sysctl." \
    || echo "[rkz-vpn] Sysctl IPv6 non applicable ici (ok si ip6tables a pris le relais)."
}

tunnel_is_healthy() {
  ip addr show tun0 >/dev/null 2>&1 && pgrep openvpn >/dev/null 2>&1
}

write_status() {
  state_label="$1"      # "true" | "false" (tout autre valeur est traitée comme "false")
  ip_label="$2"
  case "$state_label" in true) ;; *) state_label="false" ;; esac

  # IP publique : rafraîchie seulement à la première connexion, après chaque
  # reconnexion (l'IP de sortie peut changer) et une fois par heure, pas à
  # chaque tick (évite le rate-limiting du service ifconfig.me).
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
    [ -z "$ip_label" ] && ip_label="indisponible"
  fi
  PREV_STATE="$state_label"

  cat > /config/vpn-status.json <<EOF
{
  "last_check": "$(date -Iseconds)",
  "tunnel_up": $state_label,
  "public_ip": "$ip_label"
}
EOF
}

graceful_shutdown() {
  echo "[rkz-vpn] $(date '+%F %T') Arrêt de Transmission (flush settings/resume)..."
  if [ -n "$TRANSMISSION_PID" ]; then
    kill -TERM "$TRANSMISSION_PID" 2>/dev/null
    for i in $(seq 1 20); do
      kill -0 "$TRANSMISSION_PID" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$TRANSMISSION_PID" 2>/dev/null && kill -9 "$TRANSMISSION_PID" 2>/dev/null
  fi
  pkill openvpn 2>/dev/null
  echo "[rkz-vpn] Arrêt terminé."
  exit 0
}

# sleep par tranches de 1s : interruptible par le signal d'arrêt, et utilisé
# par le backoff (délai croissant entre les tentatives de reconnexion).
sleep_interruptible() {
  t=0
  while [ "$t" -lt "$1" ]; do
    [ "$STOPPING" = "1" ] && return 1
    sleep 1
    t=$((t + 1))
  done
  return 0
}

# (re)connexion du tunnel avec backoff exponentiel (10s -> RETRY_DELAY_MAX).
# Retourne 1 si un arrêt a été demandé en cours de route, 0 sinon.
reconnect() {
  write_status "false" "reconnexion en cours"
  until [ "$STOPPING" = "1" ] || start_vpn; do
    echo "[rkz-vpn] Nouvelle tentative dans ${RETRY_DELAY}s..."
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
  echo "[rkz-vpn] $(date '+%F %T') Tunnel rétabli."
}

# -----------------------------------------------------------------------------
# 1. IPv6 off dès le départ, puis premier démarrage du tunnel
# -----------------------------------------------------------------------------
disable_ipv6_sysctl

reconnect || graceful_shutdown

# -----------------------------------------------------------------------------
# 2. Config Transmission : seed uniquement si pas déjà présente.
#    chown non récursif : seuls les dossiers de premier niveau, jamais tout
#    l'arbre existant (évite un chown -R interminable sur un volume chargé).
# -----------------------------------------------------------------------------
mkdir -p /config /data/completed /data/incomplete /data/watch
[ -f /config/settings.json ] || cp /settings.default.json /config/settings.json
chown rakiz:rakiz /config /data /data/completed /data/incomplete /data/watch 2>/dev/null

# -----------------------------------------------------------------------------
# 3. Démarrage de Transmission en arrière-plan
# -----------------------------------------------------------------------------
su-exec rakiz:rakiz transmission-daemon --foreground --config-dir /config &
TRANSMISSION_PID=$!
echo "[rkz-vpn] Transmission démarré (PID $TRANSMISSION_PID)."
write_status "true"

# -----------------------------------------------------------------------------
# 4. Boucle de surveillance : réveil toutes les 1s pour réagir vite à un
#    signal d'arrêt, mais vérification réelle du tunnel toutes les
#    CHECK_INTERVAL secondes seulement.
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
    echo "[rkz-vpn] $(date '+%F %T') Tunnel down détecté, reconnexion..."
    reconnect || break
  elif [ "$ZOMBIE_THRESHOLD" -gt 0 ]; then
    # Tunnel "en vie" (tun0 + process) mais qui ne passe plus de trafic :
    # on sonde via tun0. Après ZOMBIE_THRESHOLD échecs, reconnexion forcée.
    if ping -c 1 -W 3 -I tun0 1.1.1.1 >/dev/null 2>&1; then
      ZOMBIE_COUNT=0
    else
      ZOMBIE_COUNT=$((ZOMBIE_COUNT + 1))
      echo "[rkz-vpn] $(date '+%F %T') Tunnel actif mais sans trafic ($ZOMBIE_COUNT/$ZOMBIE_THRESHOLD)..."
      if [ "$ZOMBIE_COUNT" -ge "$ZOMBIE_THRESHOLD" ]; then
        echo "[rkz-vpn] $(date '+%F %T') Tunnel zombie, reconnexion forcée..."
        ZOMBIE_COUNT=0
        reconnect || break
      fi
    fi
  fi

  write_status "true"

  if ! kill -0 "$TRANSMISSION_PID" 2>/dev/null; then
    echo "[rkz-vpn] $(date '+%F %T') Transmission s'est arrêté de façon inattendue."
    echo "[rkz-vpn] Sortie du conteneur pour laisser Docker le relancer proprement."
    exit 1
  fi
done

graceful_shutdown
