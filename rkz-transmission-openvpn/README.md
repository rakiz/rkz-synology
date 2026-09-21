# rkz-transmission-openvpn

BitTorrent client **Transmission** behind an **OpenVPN** tunnel, in a single lightweight Docker container, designed for a **Synology NAS** (Container Manager) and driven remotely through RPC.

```
┌─────────────────── Synology (DSM + Container Manager) ─────────────────────────┐
│                                                                                │
│  ┌── container (alpine:3.20) ──────────────────────────────────────────────┐   │
│  │  entrypoint.sh                                                          │   │
│  │    ├─ OpenVPN ──► tun0  (your .ovpn file, mounted - provider-agnostic)  │   │
│  │    ├─ iptables/ip6tables kill switch                                    │   │
│  │    ├─ Transmission (non-root, via setpriv)                             │   │
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
- **Non-root Transmission**: OpenVPN runs as root (required for `NET_ADMIN`/`tun0`), Transmission is started through `setpriv --init-groups` with a dedicated user — the group initialization matters: on Synology, the data folders' ACLs allow the GID 101 group, which the user must keep after the privilege drop.
- **Status file** `/config/vpn-status.json` (public IP seen, timestamp, tunnel state): check that it works without having to look actively.
- **Clean shutdown**: if Transmission dies, the container exits and Docker restarts it (`restart: unless-stopped`). On `docker stop`, the signal is handled within ~1 s, Transmission gets up to 20 s to flush its `.resume`/`settings.json` files, and `stop_grace_period: 30s` keeps Docker from cutting the procedure short.

## Architecture choices

| Choice | Rationale |
|---|---|
| **Plain Alpine 3.20**, not `linuxserver/transmission` | linuxserver ships s6-overlay (multi-process supervision, PUID/PGID, init scripts) which adds nothing for a simple startup flow. Image of a few dozen MB instead of 100+. |
| **OpenVPN, not WireGuard** | Synology DSM kernels (3.10/4.4) usually lack the WireGuard kernel module and Synology locks third-party module loading on most models. OpenVPN works with just the `NET_ADMIN` capability. |
| **Kill switch by IP ranges, not by interface name** | The container's network interface name is not guaranteed (`eth0`, `br-*` depending on DSM); the rules match private IP ranges, not an interface name. |
| **Hand-written entry script** | ~650 lines of POSIX sh understood end to end, no third-party abstraction layer to trust or update. |
| **Peer port 51413 not published** | Intentional: peers reach the client through the tunnel (`tun0`). Publishing it on the host is useless (CyberGhost has no port forwarding) and is a leak vector. |
| **No `logging:` block in docker-compose.yml** | Synology's Container Manager Journal reads its own `db` log driver: overriding it with `json-file` keeps `docker logs` working but leaves the Journal tab permanently empty. |
| **All configuration comes from volumes** | The image contains no settings: the `.ovpn`, `credentials.txt` and `settings.json` all live on the NAS — one single mental model, and manual tweaks survive image upgrades by design. |

## Repository layout

```
rkz-transmission-openvpn/
├── docker-compose.yml              # Container Manager / docker compose deployment
├── docker/
│   ├── Dockerfile                  # Alpine 3.20 + openvpn, transmission-daemon, util-linux (setpriv), iptables, ip6tables, iptables-legacy, procps, ca-certificates, tzdata
│   └── entrypoint.sh               # Tunnel + kill switch + watchdog (~650 lines of POSIX sh)
├── configuration/
│   ├── README.md                   # How to configure OpenVPN and Transmission
│   ├── settings.json.example       # Template for the Transmission settings (copy it to your /config volume)
│   └── credentials.txt.example     # Template for the OpenVPN credentials file (2 lines)
├── openvpn/                        # YOUR real VPN files (gitignored: .ovpn, certs, credentials.txt)
├── config/                         # created at deploy: Transmission's live state (settings.json + .resume)
├── LICENSE                         # MIT
└── README.md
```

## Installation (Synology)

### 0. Get the repository on the NAS

No SSH needed — File Station only:

1. On GitHub: **Code → Download ZIP** (green button on the repo page).
2. In DSM **File Station**: upload the zip in the `/volume1/docker` shared folder, right-click → **Extract**.
3. The zip extracts a `rkz-synology-main` folder: rename it to `rkz-synology` — the project then lives at `/volume1/docker/rkz-synology/rkz-transmission-openvpn/`, with `docker-compose.yml` directly inside that subfolder.

(Comfortable with SSH? `git clone https://github.com/rakiz/rkz-synology.git /volume1/docker/rkz-synology` does the same — and makes updates easier later.)

### 1. Provider OpenVPN credentials

These are **OpenVPN-dedicated credentials**, different from the website login. For CyberGhost: log in at [my.cyberghostvpn.com](https://my.cyberghostvpn.com), "OpenVPN manual configuration" section, download the `.ovpn` of the desired country and note the OpenVPN login/password provided there. See [configuration/README.md](configuration/README.md) for the full walkthrough.

### 2. Prepare the NAS

```bash
mkdir -p config
cp configuration/settings.json.example config/settings.json

# VPN folder: INSIDE the project folder (already gitignored)
# → upload openvpn.ovpn, ca.crt, client.crt, client.key and credentials.txt there
#   via File Station, from the openvpn/ folder of your Mac copy
/volume1/docker/rkz-synology/rkz-transmission-openvpn/openvpn/
```

Volumes — the project folders for the configuration and VPN files, the existing torrents folder for the data:

```yaml
volumes:
  - ./config:/config                # the project's config/ folder — Transmission's live state
  - /volume1/torrents:/data         # completed/ incomplete/ watch/ — your existing data, untouched
  - ./openvpn:/openvpn:ro           # .ovpn + credentials.txt
```

### 3. Configure the RPC

Edit `/volume1/docker/rkz-synology/rkz-transmission-openvpn/config/settings.json` (created in the previous step), replace:

- `"rpc-password": "changeme"` → the desired password (hashed automatically on the first start),
- `"rpc-username": "username"` → the desired username, if you want a different one.

### 4. Build + run

In Container Manager: **Project → Create**, open the project from its subdirectory — project path `/volume1/docker/rkz-synology/rkz-transmission-openvpn`, source **use the existing docker-compose.yml** at that path → **Build** (first build takes a few minutes) → start the project.

Command line equivalent, if SSH is enabled:

```bash
cd /volume1/docker/rkz-synology/rkz-transmission-openvpn
docker compose up -d --build
```

### 5. Remote client (Windows) and Homepage

Same URL scheme as any Transmission RPC client: `http://NAS_IP:59091`, RPC URL `/transmission/`.

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

Note: existing installs deployed from the old standalone repo keep working as-is; the paths above describe a fresh monorepo clone.

## Updating later

Configuration and data live on NAS volumes — updating the code or the image never touches them (`settings.json`, `.resume` files, torrents all survive).

Without SSH (File Station + Container Manager):

1. Download the new ZIP on GitHub, extract it on your Mac.
2. Via File Station, replace in `/volume1/docker/rkz-synology/rkz-transmission-openvpn/` everything EXCEPT the `openvpn/` folder (your secrets) — or simply overwrite the files the new version changed.
3. Container Manager → your project → **Rebuild** (or Stop + Build + Start).

With SSH:

```bash
cd /volume1/docker/rkz-synology/rkz-transmission-openvpn
git pull
docker compose up -d --build
```

- `settings.json` is never overwritten by an update: if a new version ships a new template, diff it manually against `configuration/settings.json.example` and port what you want.
- To roll back: `git checkout <previous commit or tag>` then rebuild.
- Old images can be cleaned with `docker image prune`.

## Checking it works

```bash
# Status: public IP as seen through the tunnel, tunnel state, timestamp
cat /volume1/docker/rkz-synology/rkz-transmission-openvpn/config/vpn-status.json
```

```json
{
  "last_check": "2026-09-18T15:42:07+02:00",
  "tunnel_up": true,
  "public_ip": "xx.xx.xx.xx"
}
```

The IP shown must be the VPN server's, not the ISP/router IP. If the tunnel drops, `tunnel_up` immediately turns to `false` (state `reconnecting...`) — no misleading frozen state while reconnecting. The public IP is refreshed on first connect, after each reconnect and once an hour. Right after boot, the IP may stay `unavailable` for ~30-60 s (the tunnel needs a moment to pass traffic) — it fills in on its own, no restart needed.

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
| `[openvpn] ... Cannot open TUN/TAP dev /dev/net/tun` | tun device not passed | the tun kernel module is missing on the host — `sudo insmod /lib/modules/tun.ko` (see Known limitations) |
| `error gathering device information ... /dev/net/tun` ( Container Manager journal, container stuck in `Created`) | tun kernel module not loaded on the host | `sudo insmod /lib/modules/tun.ko`, then rebuild the project |
| `tunnel_up: true` but `public_ip` shows your real ISP/router IP | traffic leaking around the tunnel | bug — open an issue with the logs |
| `[rkz-vpn] ERROR: Transmission exited unexpectedly` + container restarts | daemon crash | check the /config volume ownership (UID 1000) |
| `WARN: ip6tables unavailable on this host` | host kernel lacks `ip6_tables` | IPv6 protection relies on the sysctl; verify `cat /proc/sys/net/ipv6/conf/all/disable_ipv6` returns `1` |
| repeated `reconnecting in 60s...` | persistent failure (credentials, DNS, or unreachable server) | read the `[openvpn]` lines just above |
| Journal tab empty in Container Manager (while `docker logs` works) | the compose overrides Synology's `db` log driver — do NOT add a `logging:` block (see Architecture choices) | remove the `logging:` block and rebuild the project |

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

The paths in `docker-compose.yml` are examples: the project's `./config` and `./openvpn` folders, and `/volume1/torrents` for the data — edit the paths in `docker-compose.yml` directly. Builds are checked on every push by a GitHub Actions CI (shellcheck, JSON, build + smoke test).

Multi-arch build (amd64 + arm64):

```bash
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -t YOUR_HANDLE/rkz-transmission-openvpn:1.0 \
  --push .
```

## Known limitations

- **tun kernel module**: the container creates its own `/dev/net/tun` node, but the kernel module must exist. If it is not loaded (fresh DSM boot), load it once: `sudo insmod /lib/modules/tun.ko` — and add the same command to a boot-up task (DSM Task Scheduler) so it survives reboots.
- **`ip6_tables` kernel module on the host**: if missing (possible on DSM), the logs show `ip6tables unavailable on this host` and IPv6 protection relies only on the sysctl (now enforced at container creation by the `sysctls:` block in docker-compose.yml) — then verify that `docker exec rkz-transmission-openvpn cat /proc/sys/net/ipv6/conf/all/disable_ipv6` returns `1`.
- **`xt_owner` iptables match**: missing on Synology DSM kernels, so the kill switch cannot restrict the VPN-transport and DNS holes to uid 0 (OpenVPN only); the logs announce it (`WARN: xt_owner unavailable on this kernel`). Default-deny still holds, and torrent traffic only ever leaves through `tun+`.
- **Container network interface name**: not guaranteed to be `eth0` depending on DSM; the kill switch matches private IP ranges rather than interface names, which limits the risk. If the LAN is unreachable at startup: `docker exec rkz-transmission-openvpn ip addr`.
- **Zombie probe uses ICMP**: it pings `1.1.1.1` through `tun0`. If your VPN provider blocks ICMP, set `ZOMBIE_THRESHOLD=0` to disable the probe (the base watchdog stays active).

## Tested on

- Synology **DS920+ (Intel)** and **DS925+ (AMD)** — x86_64/amd64 — with **Container Manager** (`docker compose` deployment)
- VPN provider: **CyberGhost** (OpenVPN, manual configuration)
- RPC client: Transmission Remote GUI / Windows equivalent, and the native Homepage widget

## License

[MIT](LICENSE) — © 2026 rakiz
