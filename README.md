# rkz-transmission-openvpn

BitTorrent client **Transmission** behind an **OpenVPN** tunnel, in a single lightweight Docker container, designed for a **Synology NAS** (Container Manager) and driven remotely through RPC.

```
┌─────────────────── Synology (DSM + Container Manager) ─────────────────────────┐
│                                                                                │
│  ┌── container (alpine:3.20) ──────────────────────────────────────────────┐   │
│  │  entrypoint.sh                                                          │   │
│  │    ├─ OpenVPN ──► tun0  (your .ovpn file, mounted - provider-agnostic)  │   │
│  │    ├─ iptables/ip6tables kill switch                                    │   │
│  │    ├─ Transmission (non-root, via su-exec)                              │   │
│  │    └─ Watchdog: tunnel dead or zombie? → reconnect + re-apply kill      │   │
│  │         switch, in a loop, with no human intervention                   │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│         │ RPC 59091                      │ /config/vpn-status.json              │
│         ▼                                ▼                                     │
│   Windows client / Homepage widget   Visual health check                       │
└────────────────────────────────────────────────────────────────────────────────┘
```

## What it does

- **Brings up an OpenVPN tunnel** from a single `.ovpn` file mounted as a volume. No provider is hard-coded: CyberGhost today, another one tomorrow, without changing a line of code.
- **iptables kill switch**: `INPUT`/`OUTPUT`/`FORWARD` policies set to `DROP`; only the loopback, `tun0`, the private ranges (LAN, to keep RPC reachable) and the VPN server itself are allowed. The same treatment is applied to **IPv6** (`ip6tables`), completed by a sysctl that disables IPv6 entirely as defense in depth (useful if the host lacks the `ip6_tables` module). LAN access is limited to the RPC port; the only requests allowed outside the tunnel are DNS queries (required for reconnection) — never torrent traffic.
- **Self-repair**: a watchdog wakes up every second and runs real checks every 30 s: `tun0` present and OpenVPN alive. If not: reconnect in a loop, re-apply the kill switch, update the status file. The tunnel is also probed through `tun0` (ping): a tunnel that is alive but carries no traffic is reconnected after `ZOMBIE_THRESHOLD` consecutive failures.
- **Non-root Transmission**: OpenVPN runs as root (required for `NET_ADMIN`/`tun0`), Transmission is started through `su-exec` with a dedicated user.
- **Status file** `/config/vpn-status.json` (public IP seen, timestamp, tunnel state): check that it works without having to look actively.
- **Clean shutdown**: if Transmission dies, the container exits and Docker restarts it (`restart: unless-stopped`). On `docker stop`, the signal is handled within ~1 s, Transmission gets up to 20 s to flush its `.resume`/`settings.json` files, and `stop_grace_period: 30s` keeps Docker from cutting the procedure short.

## Why this project

Replacement for an old `haugene/docker-transmission-openvpn` setup, image frozen since 2023, which masked regular crashes behind an automatic restart without ever fixing them. Here: simple code (~300 lines of shell), fully understood, updated only when decided — no dependency on a third-party project (neither haugene, nor gluetun).

## Architecture choices

| Choice | Rationale |
|---|---|
| **Plain Alpine 3.20**, not `linuxserver/transmission` | linuxserver ships s6-overlay (multi-process supervision, PUID/PGID, init scripts) which adds nothing for a simple startup flow. Image of a few dozen MB instead of 100+. |
| **OpenVPN, not WireGuard** | Synology DSM kernels (3.10/4.4) usually lack the WireGuard kernel module and Synology locks third-party module loading on most models. OpenVPN works with just the `NET_ADMIN` capability. |
| **Kill switch by IP ranges, not by interface name** | The container's network interface name is not guaranteed (`eth0`, `br-*` depending on DSM); the rules match private IP ranges, not an interface name. |
| **Hand-written entry script** | ~300 lines of shell understood end to end, rather than a third-party abstraction layer that is itself a source of bugs (open issues on haugene and gluetun specifically for CyberGhost). |
| **Peer port 51413 not published** | Intentional: peers reach the client through the tunnel (`tun0`). Publishing it on the host is useless (CyberGhost has no port forwarding) and is a leak vector. |
| **All configuration comes from volumes** | The image contains no settings: the `.ovpn`, `credentials.txt` and `settings.json` all live on the NAS — one single mental model, and manual tweaks survive image upgrades by design. |

## Repository layout

```
rkz-transmission-openvpn/
├── docker/
│   ├── Dockerfile                  # Alpine 3.20 + openvpn, transmission-daemon, su-exec, iptables, ip6tables, procps, ca-certificates, tzdata
│   ├── entrypoint.sh               # Tunnel + kill switch + watchdog (~300 lines of POSIX sh)
│   └── docker-compose.yml          # Container Manager / docker compose deployment
├── configuration/
│   ├── README.md                   # How to configure OpenVPN and Transmission
│   ├── settings.json.example       # Template for the Transmission settings (copy it to your /config volume)
│   └── credentials.txt.example     # Template for the OpenVPN credentials file (2 lines)
├── LICENSE                         # MIT
└── README.md
```

## Installation (Synology)

### 1. Provider OpenVPN credentials

These are **OpenVPN-dedicated credentials**, different from the website login. For CyberGhost: log in at [my.cyberghostvpn.com](https://my.cyberghostvpn.com), "OpenVPN manual configuration" section, download the `.ovpn` of the desired country and note the OpenVPN login/password provided there. See [configuration/README.md](configuration/README.md) for the full walkthrough.

### 2. Prepare the NAS

```bash
# VPN folder (the .ovpn file name is free: the first *.ovpn found is used)
mkdir -p /volume1/docker/rkz-vpn/openvpn
# → drop the .ovpn file and credentials.txt there (2 lines: login then password)
sudo chmod 600 /volume1/docker/rkz-vpn/openvpn/credentials.txt
# Transmission settings: copy the template into the /config volume, then edit it
cp configuration/settings.json.example /volume1/docker/transmission-home/settings.json
```

Existing data folders are reused as is:

```yaml
volumes:
  - /volume1/docker/transmission-home:/config    # Transmission config + vpn-status.json
  - /volume1/torrents:/data                      # completed/ incomplete/ watch/
  - /volume1/docker/rkz-vpn/openvpn:/openvpn:ro  # .ovpn + credentials.txt
```

### 3. Configure the RPC

The settings file is the one you just copied to `/volume1/docker/transmission-home/settings.json` (if you are reusing a `/volume1/docker/transmission-home` folder from a previous setup, it already contains a `settings.json` — review it instead of overwriting it). Replace:

- `"rpc-password": "changeme"` → the desired password (Transmission hashes it itself on first start),
- `"rpc-username": "username"` → the desired username.

### 4. Build + run

```bash
cd /volume1/docker/rkz-transmission-openvpn/docker
docker compose build
docker compose up -d
```

In Container Manager, point the compose file to `docker/docker-compose.yml`.

### 5. Remote client (Windows) and Homepage

No configuration change on the client side: same host, same RPC URL, same credentials as the old setup.

- **RPC client**: `http://NAS_IP:59091`, RPC URL `/transmission/`
- **Homepage widget** (gethomepage/homepage):

```yaml
- Transmission:
    icon: transmission.png
    href: http://NAS_IP:59091
    widget:
      type: transmission
      url: http://NAS_IP:59091
      username: username
      password: YOUR_RPC_PASSWORD_IN_CLEAR
      rpcUrl: /transmission/
```

## Checking it works

```bash
# Status: public IP as seen through the tunnel, tunnel state, timestamp
docker exec rkz-transmission-openvpn cat /config/vpn-status.json
```

```json
{
  "last_check": "2026-09-18T15:42:07+02:00",
  "tunnel_up": true,
  "public_ip": "xx.xx.xx.xx"
}
```

The IP shown must be the VPN server's, not the ISP/router IP. If the tunnel drops, `tunnel_up` immediately turns to `false` (state `reconnecting...`) — no misleading frozen state while reconnecting. The public IP is refreshed on first connect, after each reconnect and once an hour.

## Reading the logs

Everything lands on stdout — in Container Manager: container → **Log** tab (or `docker logs -f rkz-transmission-openvpn`). Two kinds of lines:

- `[rkz-vpn]` — the entrypoint itself (`OK:` / `INFO:` / `WARN:` / `ERROR:`),
- `[openvpn]` — the tunnel's own log, streamed in real time (this is where the actual cause of a failure shows).

| You see | Meaning | What to do |
|---|---|---|
| `[openvpn] ... Initialization Sequence Completed` | tunnel is UP | nothing — this is the green line |
| `[rkz-vpn] ERROR: no .ovpn file found in /openvpn` | the .ovpn volume is empty or misdirected | check the volume mapping, or set `OVPN_FILE` |
| `[rkz-vpn] ERROR: /openvpn/credentials.txt not found` | credentials file missing | create it (2 lines: login, password) |
| `[openvpn] ... AUTH_FAILED` / authentication errors | wrong VPN credentials | `credentials.txt` must hold the provider's **OpenVPN-dedicated** login, not the website one |
| `[openvpn] ... could not resolve host` / resolution errors | DNS problem | keep the DNS egress rules in the kill switch; check the NAS DNS configuration |
| `[openvpn] ... Cannot open TUN/TAP dev /dev/net/tun` | tun device not passed | keep `devices: /dev/net/tun` and `cap_add: NET_ADMIN` in the compose |
| `tunnel_up: true` but `public_ip` shows your real ISP/router IP | traffic leaking around the tunnel | bug — open an issue with the logs |
| `[rkz-vpn] ERROR: Transmission exited unexpectedly` + container restarts | daemon crash | check the /config volume ownership (UID 1000) |
| `WARN: ip6tables unavailable on this host` | host kernel lacks `ip6_tables` | IPv6 protection relies on the sysctl; verify `cat /proc/sys/net/ipv6/conf/all/disable_ipv6` returns `1` |
| repeated `reconnecting in 60s...` | persistent failure (credentials, DNS, or unreachable server) | read the `[openvpn]` lines just above |

## Configuration

| Variable / file | Role | Default |
|---|---|---|
| `OVPN_FILE` (env) | Path of the `.ovpn` inside the container | First `*.ovpn` found in `/openvpn/` |
| `credentials.txt` | 2 lines: OpenVPN login then password | `/openvpn/credentials.txt` |
| `CHECK_INTERVAL` (env) | Watchdog period in seconds | `30` |
| `ZOMBIE_THRESHOLD` (env) | Consecutive failed pings through `tun0` before forcing a reconnect of a "zombie" tunnel; `0` disables the probe | `3` |
| `RETRY_DELAY_MAX` (env) | Cap of the exponential backoff between reconnect attempts (seconds) | `60` |
| `TZ` (docker-compose.yml) | Timezone of `vpn-status.json` timestamps and logs (needs tzdata) | `Europe/Paris` |
| `configuration/settings.json.example` | Template for the Transmission settings — copy it to your `/config` volume as `settings.json` and edit it | — |

For the OpenVPN and Transmission settings themselves (what to put in the `.ovpn`, what each Transmission knob does, how to change settings after the first boot), see [configuration/README.md](configuration/README.md).

## Reusing this project

The image contains **no secret**: the `.ovpn` file, the OpenVPN credentials and the RPC password are mounted/configured at runtime, never copied into the image. Every deployment uses its own VPN subscription (`.ovpn` + dedicated credentials — most providers limit simultaneous connections per account).

The Synology paths in `docker-compose.yml` are examples: set `VOL_CONFIG`, `VOL_TORRENTS` and `VOL_OPENVPN` in a `docker/.env` file (defaults are the original Synology's). Builds are checked on every push by a GitHub Actions CI (shellcheck, JSON, build + smoke test).

Multi-arch build (amd64 + arm64):

```bash
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -t YOUR_HANDLE/rkz-transmission-openvpn:1.0 \
  --push .
```

## Known limitations

- **`ip6_tables` kernel module on the host**: if missing (possible on DSM), the logs show `ip6tables unavailable on this host` and IPv6 protection relies only on the sysctl — then verify that `docker exec rkz-transmission-openvpn cat /proc/sys/net/ipv6/conf/all/disable_ipv6` returns `1`.
- **Container network interface name**: not guaranteed to be `eth0` depending on DSM; the kill switch matches private IP ranges rather than interface names, which limits the risk. If the LAN is unreachable at startup: `docker exec rkz-transmission-openvpn ip addr`.
- **Zombie probe uses ICMP**: it pings `1.1.1.1` through `tun0`. If your VPN provider blocks ICMP, set `ZOMBIE_THRESHOLD=0` to disable the probe (the base watchdog stays active).

## Tested on

- Synology **DS920+ (Intel)** and **DS925+ (AMD)** — x86_64/amd64 — with **Container Manager** (`docker compose` deployment)
- VPN provider: **CyberGhost** (OpenVPN, manual configuration)
- RPC client: Transmission Remote GUI / Windows equivalent, and the native Homepage widget

## License

[MIT](LICENSE) — © 2026 rakiz
