# rkz-synology

Dockerized self-hosted apps for Synology DSM, deployed with Container Manager. One Git repo, one project per subdirectory.

## Layout

| Directory | Project | Status |
|---|---|---|
| [`rkz-transmission-openvpn/`](rkz-transmission-openvpn/) | Transmission + OpenVPN with a kill switch | live |
| `rkz-arr/` | Radarr / Sonarr / Prowlarr stack | planned |
| `rkz-plex/` | Plex media server | planned |

## Shared conventions

- **Deploy with Container Manager** (Project → open the subdirectory's `docker-compose.yml`): after file updates, Stop → Build → Start; a plain Start does not recreate containers.
- **Never add a `logging:` block** to a compose file: Container Manager's Journal reads its own `db` log driver and any override leaves the Journal tab empty. Details in each project's README.
- **Harden at creation time**: kernel-level sysctls (e.g. IPv6 disabling) belong in the compose `sysctls:` block — a runtime `sysctl -w` cannot work, `/proc/sys` is read-only in the container.
- **Secrets stay out of Git**: credentials live in each project's `openvpn/` folder, mode 600.
