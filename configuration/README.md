# Configuring rkz-transmission-openvpn

Everything you need to fill in lives in two places: the **OpenVPN side** (one `.ovpn` profile + one credentials file) and the **Transmission side** (one JSON settings file). No VPN provider and no credential is ever hard-coded in the image.

The two files in this folder are **templates**:

| File | Role |
|---|---|
| `credentials.txt.example` | model for the OpenVPN credentials file (copy as `credentials.txt` on the NAS) |
| `settings.json.example` | model for the Transmission settings (copy as `settings.json` into the project's `config/` folder) |

The **real** files live on the NAS (paths below) and are never committed: `.gitignore` and `.dockerignore` block them.

---

## OpenVPN side

### What the container expects

| File | Location in container | Content |
|---|---|---|
| `<anything>.ovpn` | `/openvpn/` (mounted read-only) | the OpenVPN profile downloaded from your provider |
| `credentials.txt` | `/openvpn/credentials.txt` | 2 lines: OpenVPN login, then OpenVPN password |

- The first `*.ovpn` found in `/openvpn` is used automatically. Several profiles in the folder? Set the env var `OVPN_FILE=/openvpn/<name>.ovpn`.
- `credentials.txt` holds **OpenVPN-specific credentials** — on most providers (CyberGhost, NordVPN, PIA...) they are **not** your website login. `chmod 600` recommended.
- On the NAS, these files sit in the project's `openvpn/` sub-folder (`/volume1/docker/rkz-transmission-openvpn/openvpn/` — the folder mounted on `/openvpn` in `docker-compose.yml`).

### With CyberGhost (concrete example)

1. Log in at [my.cyberghostvpn.com](https://my.cyberghostvpn.com) → "OpenVPN manual configuration".
2. Pick the desired country server, download its `.ovpn` file.
3. Note the dedicated OpenVPN login/password displayed on the same page.
4. Copy the `.ovpn` into the project's `openvpn/` sub-folder on the NAS (`/volume1/docker/rkz-transmission-openvpn/openvpn/`) and create `credentials.txt` there (login on line 1, password on line 2 — use `credentials.txt.example` from this folder as the model).

Any other classic OpenVPN provider works the same way: drop its `.ovpn` and its credentials, nothing else to change.

### What the entrypoint actually reads in your .ovpn

- `remote <host> <port>` (first match) and `proto udp|tcp`: used to open a single firewall hole so the tunnel can be (re)established while the kill switch is active. A missing port defaults to 1194; `proto` variants (`udp4`, `tcp-client`...) are normalized automatically.
- Everything else in the file (CA certificate, cipher, auth settings) is used by OpenVPN itself — keep the file as downloaded, do not trim it.
- If `remote` uses a hostname, reconnection relies on DNS: the kill switch intentionally allows DNS queries out (and nothing else) for exactly that purpose.

---

## Transmission side

### How settings work here

- There is **no settings file inside the image**: like the `.ovpn` and `credentials.txt`, the Transmission settings are **provided by you on the NAS volume** (`/volume1/docker/rkz-transmission-openvpn/config/settings.json` — copy the template `settings.json.example` from this folder to there).
- The RPC password is written in clear text in the file; the daemon replaces it with a hash on first start.
- If `settings.json` is missing at startup, the container exits immediately with an error message telling you the exact copy command — it never runs with silent default settings.
- To change settings later: stop the container first (`docker compose stop`) — Transmission rewrites `settings.json` when it exits, so editing it while running gets overwritten — then edit `/volume1/docker/rkz-transmission-openvpn/config/settings.json` (or change values live from your RPC client, they are persisted too), then `docker compose start`.

### The settings that matter

| Setting | Why |
|---|---|
| `rpc-username` / `rpc-password` | credentials used by your Windows RPC client and the Homepage widget |
| `rpc-url` (`/transmission/`) | keep consistent with the client and the Homepage `rpcUrl` |
| `rpc-port` (`9091`) | published as `59091` on the host — clients connect to `NAS_IP:59091` |
| `download-dir` (`/data/completed`) | finished torrents (host: `/volume1/torrents/completed`) |
| `incomplete-dir` + `incomplete-dir-enabled` | partial downloads (host: `/volume1/torrents/incomplete`) |
| `watch-dir` (`/data/watch`) + enabled | drop a `.torrent` file there → auto-added |
| `peer-port` (`51413`) | internal only, reached through the VPN tunnel — deliberately **not** published on the host |
| `bind-address-ipv4` (`0.0.0.0`) | keep broad: the tunnel interface's IP is dynamic |
| `umask` (`2`) | files created `664` / dirs `775` (usable by the shared group) |
| `cache-size-mb`, `peer-limit-*`, `speed-limit-*` | tuning knobs; `*-enabled: false` means the limit does not apply |

Official reference: the Transmission configuration documentation in the [transmission/transmission](https://github.com/transmission/transmission) repository (`docs/Configuration.md`).

---

## Environment variables (recap)

| Variable | Role | Default |
|---|---|---|
| `OVPN_FILE` | Path of the `.ovpn` inside the container | first `*.ovpn` in `/openvpn/` |
| `CHECK_INTERVAL` | Watchdog period (seconds) | `30` |
| `ZOMBIE_THRESHOLD` | Failed pings through `tun0` before forcing a reconnect; `0` disables | `3` |
| `RETRY_DELAY_MAX` | Cap of the reconnect backoff (seconds) | `60` |
| `TZ` | Timezone for logs and `vpn-status.json` | `Europe/Paris` |

When a check fails, the ["Reading the logs"](../README.md#reading-the-logs) section of the root README maps what you see to what to fix.
