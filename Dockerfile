FROM alpine:3.20

# --- Paquets minimaux : openvpn + transmission-daemon + su-exec pour drop de privilèges + iptables pour le kill switch
RUN apk add --no-cache \
    openvpn \
    transmission-daemon \
    su-exec \
    iptables \
    ip6tables \
    procps \
    ca-certificates \
    tzdata

# --- Utilisateur non-root pour faire tourner transmission-daemon
RUN addgroup -g 1000 rakiz && \
    adduser -D -u 1000 -G rakiz rakiz && \
    mkdir -p /config /data/completed /data/incomplete /data/watch && \
    chown -R rakiz:rakiz /data

COPY entrypoint.sh /entrypoint.sh
COPY settings.default.json /settings.default.json
RUN chmod +x /entrypoint.sh

# Seul le RPC est destiné à être exposé sur l'hôte. Le trafic pair-à-pair
# (port peer 51413) transite exclusivement par tun0, jamais par l'hôte
# (CyberGhost n'a pas de port forwarding, publier ce port ne servirait à rien).
EXPOSE 9091

ENTRYPOINT ["/entrypoint.sh"]
