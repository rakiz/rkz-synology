# rkz-transmission-openvpn

Client torrent **Transmission** derrière un tunnel **OpenVPN**, dans un seul conteneur Docker léger, conçu pour un **NAS Synology** (Container Manager) et piloté exclusivement à distance via RPC.

```
┌─────────────────────── Synology (DSM + Container Manager) ───────────────────────┐
│                                                                                  │
│  ┌── conteneur (alpine:3.20) ────────────────────────────────────────────────┐   │
│  │  entrypoint.sh                                                            │   │
│  │    ├─ OpenVPN  ──► tun0  (fichier .ovpn en volume, n'importe quel         │   │
│  │    │                       fournisseur OpenVPN "classique")               │   │
│  │    ├─ Kill switch iptables (v4 + v6)                                      │   │
│  │    ├─ Transmission (non-root, via su-exec)                                │   │
│  │    └─ Watchdog 30s : tunnel mort ? → reconnexion + re-application du      │   │
│  │         kill switch, en boucle, sans intervention                         │   │
│  └───────────────────────────────────────────────────────────────────────────┘   │
│         │ RPC 59091                       │ /config/vpn-status.json              │
│         ▼                                 ▼                                      │
│   Client Windows / Homepage widget   Vérification visuelle                      │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Ce que ça fait

- **Monte un tunnel OpenVPN** à partir d'un simple fichier `.ovpn` monté en volume. Aucun fournisseur n'est codé en dur : CyberGhost aujourd'hui, un autre demain, sans changer une ligne de code.
- **Kill switch iptables + ip6tables + sysctl** : politiques `INPUT`/`OUTPUT`/`FORWARD` en `DROP`, seuls le loopback, `tun0`, les plages privées (LAN, pour garder le RPC accessible) et le serveur VPN sont autorisés. Même traitement en **IPv6** (`ip6tables` : tout IPv6 sortant bloqué, seuls loopback et préfixes link-local/ULA passent — l'accès RPC se fait via l'IPv4 du LAN), complété par une désactivation sysctl d'IPv6 en défense en profondeur (utile si le module `ip6_tables` est absent de l'hôte). Côté LAN, seul le RPC (port 9091) est accepté ; les seules requêtes autorisées hors tunnel sont des requêtes DNS (indispensables à la reconnexion) — jamais de trafic torrent.
- **Auto-réparation** : un watchdog se réveille chaque seconde et vérifie toutes les 30 s que `tun0` existe et qu'OpenVPN est vivant. Le tunnel est aussi sondé via `tun0` (ping) : un tunnel actif mais qui ne passe plus de trafic est reconnecté après `ZOMBIE_THRESHOLD` échecs consécutifs. Sinon : reconnexion en boucle, ré-application du kill switch, et mise à jour immédiate du fichier de statut.
- **Transmission non-root** : OpenVPN tourne en root (nécessaire pour `NET_ADMIN`/`tun0`), Transmission est lancé via `su-exec` avec un utilisateur dédié.
- **Fichier de statut** `/config/vpn-status.json` (IP publique vue, horodatage, état du tunnel) : on vérifie que ça fonctionne sans avoir à « checker » activement.
- **Redémarrage propre** : si Transmission meurt, le conteneur sort en erreur et Docker le relance (`restart: unless-stopped`). À l'arrêt (`docker stop`), le signal est traité en ~1 s, Transmission a jusqu'à 20 s pour flusher ses fichiers `.resume`/`settings.json`, et `stop_grace_period: 30s` empêche Docker de couper la procédure.

## Pourquoi ce projet

Remplacement d'un ancien setup `haugene/docker-transmission-openvpn`, image figée depuis 2023, qui masquait des plantages réguliers derrière un redémarrage automatique sans jamais les résoudre. Ici : du code simple (~200 lignes de shell), compris entièrement, mis à jour seulement quand on le décide — aucune dépendance à un projet tiers (ni haugene, ni gluetun).

## Choix d'architecture

| Choix | Justification |
|---|---|
| **Alpine 3.20** nue, pas `linuxserver/transmission` | linuxserver embarque s6-overlay (supervision multi-process, PUID/PGID, scripts d'init) qui n'apporte rien pour un flux de démarrage simple. Image de quelques dizaines de Mo au lieu de 100+. |
| **OpenVPN, pas WireGuard** | Les kernels Synology DSM (3.10/4.4) n'ont généralement pas le module WireGuard et verrouillent le chargement de modules tiers. OpenVPN fonctionne avec la seule capability `NET_ADMIN`. |
| **Kill switch par plages IP, pas par interface** | Le nom de l'interface réseau du conteneur n'est pas garanti (`eth0`, `br-*` selon DSM) ; les règles raisonnent sur les plages d'adresses privées, pas sur un nom d'interface. |
| **Entry script maison** | ~200 lignes de shell comprises de bout en bout, plutôt qu'une couche d'abstraction tierce elle-même source de bugs (issues ouvertes sur haugene et gluetun précisément pour CyberGhost). |
| **Port peer 51413 non publié** | Voulu : les pairs entrent par le tunnel (`tun0`). Publier 51413 sur l'hôte ne servirait à rien (CyberGhost n'a pas de port forwarding) et serait un vecteur de fuite hors VPN. |
| **Config Transmission copiée au premier boot uniquement** | Le `settings.default.json` n'est copié dans `/config` que si `settings.json` n'existe pas — jamais écrasé ensuite, pour ne pas perdre les réglages modifiés à la main sur le NAS. |

## Contenu du dépôt

```
rkz-transmission-openvpn/
├── Dockerfile                      # Alpine 3.20 + openvpn, transmission-daemon, su-exec, iptables, ip6tables, procps, ca-certificates
├── entrypoint.sh                   # Tunnel + kill switch + watchdog (~200 lignes de sh POSIX)
├── settings.default.json           # Config Transmission du premier démarrage
├── docker-compose.yml              # Déploiement Container Manager / docker compose
├── LICENSE                         # MIT
└── openvpn/
    └── credentials.txt.example     # Modèle de fichier d'identifiants OpenVPN (2 lignes)
```

## Installation sur Synology

### 1. Identifiants OpenVPN du fournisseur

Ce sont des identifiants **dédiés à OpenVPN**, différents du login du site web. Pour CyberGhost : se connecter sur [my.cyberghostvpn.com](https://my.cyberghostvpn.com), section « configuration manuelle OpenVPN », télécharger le `.ovpn` du pays voulu, noter le login/password OpenVPN fournis.

### 2. Préparer le NAS

```bash
# Dossiers VPN (le .ovpn peut porter n'importe quel nom : le premier *.ovpn trouvé est utilisé)
mkdir -p /volume1/docker/rkz-vpn/openvpn
# → y déposer le fichier .ovpn et credentials.txt (2 lignes : login puis password)
sudo chmod 600 /volume1/docker/rkz-vpn/openvpn/credentials.txt
```

Les dossiers de données existants sont réutilisés tels quels :

```yaml
volumes:
  - /volume1/docker/transmission-home:/config    # config Transmission + vpn-status.json
  - /volume1/torrents:/data                      # completed/ incomplete/ watch/
  - /volume1/docker/rkz-vpn/openvpn:/openvpn:ro  # .ovpn + credentials.txt
```

### 3. Configurer le RPC

Dans `settings.default.json`, avant le build, remplacer :

- `"rpc-password": "changeme"` → le mot de passe voulu (Transmission le hache lui-même au premier démarrage),
- `"rpc-username": "username"` → le nom d'utilisateur voulu.

### 4. Build + lancement

```bash
cd /volume1/docker/rkz-transmission-openvpn
docker compose build
docker compose up -d
```

### 5. Client distant (Windows) et Homepage

Aucune configuration à changer côté client : même hôte, même URL RPC, mêmes identifiants que l'ancien setup.

- **Client RPC** : `http://IP_DU_NAS:59091`, URL RPC `/transmission/`
- **Widget Homepage** (gethomepage/homepage) :

```yaml
- Transmission:
    icon: transmission.png
    href: http://IP_DU_NAS:59091
    widget:
      type: transmission
      url: http://IP_DU_NAS:59091
      username: username
      password: LE_MOT_DE_PASSE_RPC_EN_CLAIR
      rpcUrl: /transmission/
```

## Vérifier que ça fonctionne

```bash
# Statut : IP publique vue (donc via le tunnel), état du tunnel, horodatage
docker exec rkz-transmission-openvpn cat /config/vpn-status.json
```

```json
{
  "last_check": "2026-09-18T15:42:07+02:00",
  "tunnel_up": true,
  "public_ip": "xx.xx.xx.xx"
}
```

L'IP affichée doit être celle du serveur VPN, pas celle de la box. Si le tunnel est coupé, `tunnel_up` passe immédiatement à `false` (statut `reconnexion en cours`) — pas d'état figé trompeur pendant la reconnexion. L'IP publique est rafraîchie au premier démarrage, après chaque reconnexion (l'IP de sortie peut changer) et une fois par heure.

```bash
# Logs du entrypoint (tunnel, kill switch, watchdog, reconnexions)
docker logs -f rkz-transmission-openvpn
```

## Configuration

| Variable / fichier | Rôle | Défaut |
|---|---|---|
| `OVPN_FILE` (variable d'env) | Chemin du `.ovpn` dans le conteneur | Premier `*.ovpn` trouvé dans `/openvpn/` |
| `credentials.txt` | 2 lignes : login puis password OpenVPN | `/openvpn/credentials.txt` |
| `CHECK_INTERVAL` (variable d'env) | Période du watchdog en secondes | `30` |
| `ZOMBIE_THRESHOLD` (variable d'env) | Échecs de ping consécutifs via `tun0` avant reconnexion forcée d'un tunnel « zombie » ; `0` pour désactiver | `3` |
| `RETRY_DELAY_MAX` (variable d'env) | Plafond du backoff exponentiel entre tentatives de reconnexion (secondes) | `60` |
| `TZ` (docker-compose.yml) | Fuseau horaire des horodatages de `vpn-status.json` et des logs (tzdata requis) | `Europe/Paris` |
| `settings.default.json` | Config Transmission du **premier** démarrage | copié vers `/config/settings.json` si absent |

Autres réglages notables de `settings.default.json` : `bind-address-ipv4` à `0.0.0.0` (l'ancien setup avait l'IP tunnel NordVPN figée en dur), watch-dir activé sur `/data/watch`, `rpc-url` à `/transmission/`, `utp-enabled` à `false`.

## Points d'attention connus

- **DNS à la reconnexion** : quand le tunnel tombe, OpenVPN doit re-résoudre le hostname du serveur VPN. Le résolveur embarqué de Docker (`127.0.0.11`, joignable via loopback et la passerelle `172.16/12`, toutes deux autorisées par le kill switch) devrait suffire — à confirmer en conditions réelles. Si une reconnexion boucle, plan B : ajouter une règle DNS explicite dans `apply_killswitch()`.
- **Interface réseau du conteneur** : le nom (`eth0` ou autre) n'est pas garanti selon DSM ; le kill switch raisonnant par plages d'adresses privées, ce risque est limité. En cas de LAN inaccessible au démarrage : `docker exec rkz-transmission-openvpn ip addr` et ajuster les règles.
- **Module `ip6_tables` côté hôte** : s'il est absent (possible sur DSM), les logs affichent `ip6tables indisponible sur cet hôte` et la protection IPv6 repose uniquement sur la désactivation sysctl — vérifier alors que `docker exec rkz-transmission-openvpn cat /proc/sys/net/ipv6/conf/all/disable_ipv6` renvoie `1`.
- **Sondage zombie via ICMP** : la détection de tunnel zombie ping `1.1.1.1` à travers `tun0`. Si ton fournisseur VPN bloque l'ICMP, mets `ZOMBIE_THRESHOLD=0` pour désactiver la sonde (le watchdog de base reste actif).

## Réutiliser ce projet

L'image ne contient **aucun secret** : le `.ovpn`, les credentials OpenVPN et le mot de passe RPC sont montés/configurés au runtime, jamais copiés dans l'image. Chaque déploiement utilise son propre abonnement VPN (`.ovpn` + credentials dédiés — la plupart des fournisseurs limitent les connexions simultanées par compte).

Les chemins Synology du `docker-compose.yml` sont des exemples : définissez `VOL_CONFIG`, `VOL_TORRENTS` et `VOL_OPENVPN` dans un fichier `.env` (les valeurs par défaut sont celles du Synology d'origine). Le build est vérifié à chaque push par une CI GitHub Actions (shellcheck, JSON, build + smoke test).

Build multi-arch (amd64 + arm64) :

```bash
docker buildx create --use
docker buildx build --platform linux/amd64,linux/arm64 \
  -t TON_PSEUDO/rkz-transmission-openvpn:1.0 \
  --push .
```

## Testé sur

- Synology **DS920+ (Intel)** et **DS925+ (AMD)** — x86_64/amd64 — avec **Container Manager** (déploiement `docker compose`)
- Fournisseur VPN : **CyberGhost** (OpenVPN, config manuelle)
- Client RPC : Transmission Remote GUI / équivalent Windows, et widget natif Homepage

## Licence

[MIT](LICENSE) — © 2026 rakiz
