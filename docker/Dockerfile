FROM alpine:3.20

# Minimal package set: openvpn + transmission-daemon + su-exec for the
# privilege drop + iptables/ip6tables for the kill switch + procps for
# pgrep/pkill in the watchdog + ca-certificates for the public-IP check
# + tzdata for meaningful timestamps.
RUN apk add --no-cache \
    openvpn \
    transmission-daemon \
    su-exec \
    iptables \
    ip6tables \
    procps \
    ca-certificates \
    tzdata

# Unprivileged user for transmission-daemon (only OpenVPN needs root/NET_ADMIN)
RUN addgroup -g 1000 rakiz && \
    adduser -D -u 1000 -G rakiz rakiz && \
    mkdir -p /config /data/completed /data/incomplete /data/watch && \
    chown -R rakiz:rakiz /data

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Only the RPC port is meant to be reached from the host. Peer traffic
# (port 51413) goes through the tunnel exclusively, never through the host.
EXPOSE 9091

ENTRYPOINT ["/entrypoint.sh"]
