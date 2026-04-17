# Media Server with Docker VPN Setup

A fully automated media server stack that routes all traffic through a VPN (Gluetun). Single docker-compose file runs Plex, qBittorrent, Sonarr, Radarr, Overseerr, Prowlarr, and Flaresolverr.

## Services

| Service | Purpose | Default Port |
|---------|---------|-------------|
| [Gluetun](https://github.com/qdm12/gluetun) | VPN tunnel (WireGuard/OpenVPN) | — |
| [Plex](https://www.plex.tv/) | Media streaming | 32400 |
| [qBittorrent](https://www.qbittorrent.org/) | Torrent client | 8085 |
| [Sonarr](https://sonarr.tv/) | TV show management | 8989 |
| [Radarr](https://radarr.video/) | Movie management | 7878 |
| [Prowlarr](https://prowlarr.com/) | Indexer manager | 9696 |
| [Overseerr](https://overseerr.dev/) | Media request UI | 5055 |
| [Flaresolverr](https://github.com/FlareSolverr/FlareSolverr) | Cloudflare bypass for indexers | 8191 (internal) |

## Requirements

- Docker and Docker Compose (v2+)
- A VPN provider compatible with Gluetun (Mullvad, ProtonVPN, NordVPN, PIA, etc.) — see [Gluetun wiki](https://github.com/qdm12/gluetun-wiki) for full list
- Storage for media files (local disk, NAS mount, etc.)

## Installation

### 1. Clone the repo

```bash
git clone https://github.com/p3nguln5/Media-Server-Set-Up.git
cd Media-Server-Set-Up
```

### 2. Configure docker-compose.yaml

Edit the compose file and update:

- **VPN settings** — set your provider, WireGuard private key, and address:
  ```yaml
  - VPN_SERVICE_PROVIDER=mullvad
  - VPN_TYPE=wireguard
  - WIREGUARD_PRIVATE_KEY=your_private_key_here
  - WIREGUARD_ADDRESSES=10.x.x.x/32    # IPv4 ONLY — see note below
  ```
- **Media paths** — replace all `/path/to/media/` with your actual paths
- **Timezone** — change `America/Chicago` to your timezone
- **PUID/PGID** — set to the UID/GID that owns your media files (`id -u` / `id -g`)

> **Mullvad WireGuard note:** Download your config from https://mullvad.net/en/account/wireguard-configuration. The `.conf` file contains your PrivateKey and Address. **Use only the IPv4 address** (e.g., `10.64.253.145/32`) — strip any IPv6 `fc00::` address or gluetun will error with `interface address is IPv6 but IPv6 is not supported`.

> **Mullvad OpenVPN note:** Mullvad deprecated OpenVPN in January 2026. Use WireGuard instead.

### 3. Start the stack

```bash
docker compose up -d
```

### 4. Claim Plex (first time only)

Plex requires initial setup from `localhost`. Use an SSH tunnel:

```bash
ssh -L 32400:localhost:32400 your-server
# Then open http://localhost:32400/web in your browser and sign in
```

After claiming, Plex is accessible at `http://your-server-ip:32400/web` from any device.

### 5. Configure service connections

All services using `network_mode: "service:gluetun"` share the same network namespace. When connecting services to each other (e.g., Prowlarr → Flaresolverr, Sonarr → qBit), use the **gluetun docker bridge IP**, NOT `localhost`.

Find gluetun's bridge IP:
```bash
docker inspect gluetun --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

Example URLs (if bridge IP is `172.18.0.2`):
- Prowlarr → Flaresolverr proxy: `http://172.18.0.2:8191`
- Sonarr → qBittorrent: `http://172.18.0.2:8085`
- Sonarr → Prowlarr: `http://172.18.0.2:9696`

> **Why not localhost?** Some services (Prowlarr's .NET runtime) resolve `localhost` to IPv6 `::1` first, but Flaresolverr only listens on IPv4 `0.0.0.0`. This causes "Unable to connect to proxy" timeouts. Using the explicit bridge IP forces IPv4.

Plex uses `network_mode: host`, so from any *arr container, reach Plex at `http://your-server-ip:32400`.

## Known Issues & Fixes

### qBittorrent downloads at 0 KB/s — startup race (FIXED in this compose)

**Problem:** If qBit starts before gluetun's WireGuard tunnel is fully up, qBit binds its sockets to only `127.0.0.1` and the docker bridge — missing the VPN tunnel interface entirely. Result: 0 KB/s, no peers, no DHT.

**Root cause:** The short-form `depends_on: - gluetun` only waits for gluetun to be *running*, not for the tunnel to be *up*. qBit starts 1-2 seconds before `tun0` is created and **never rebinds** when new interfaces appear.

**Fix (already applied in this compose):** All dependent services use the long-form `depends_on` with `condition: service_healthy`:
```yaml
depends_on:
  gluetun:
    condition: service_healthy
```
Gluetun's healthcheck only passes after the tunnel is up and a public IP check succeeds.

**Quick diagnosis if you suspect this:**
```bash
# Check what IPs qBit is listening on
docker exec qbittorrent cat /config/qBittorrent/logs/qbittorrent.log | grep "Successfully listening"
```
You should see THREE IPs: `127.0.0.1`, a `172.x.x.x` bridge IP, AND your VPN tunnel IP (e.g., `10.x.x.x`). If the tunnel IP is missing, run `docker restart qbittorrent`.

### qBittorrent stops downloading after VPN reconnect — stale sockets

**Problem:** When gluetun's healthcheck fails and it reconnects to a different VPN server, the `tun0` interface is torn down and rebuilt. qBit's libtorrent session keeps the old UDP sockets. Symptoms: `connection_status: firewalled`, `dht_nodes: 0`, torrents stuck in `metaDL`.

**Quick fix:** `docker restart qbittorrent`

**Permanent fix:** Deploy the VPN watchdog — a systemd timer that checks every 2 minutes whether gluetun's public IP matches qBit's last-known IP, and auto-restarts qBit on mismatch. See [`vpn-watchdog/`](vpn-watchdog/) for the script and systemd units.

#### VPN Watchdog Setup

1. Copy files to your compose directory:
   ```bash
   cp vpn-watchdog/vpn-watchdog.sh /path/to/compose/dir/
   chmod +x /path/to/compose/dir/vpn-watchdog.sh
   ```

2. Edit `vpn-watchdog.sh` — update `COMPOSE_DIR`, `QBIT_USER`, `QBIT_PASS`, and `QBIT_PORT`.

3. Install and enable the systemd timer:
   ```bash
   sudo cp vpn-watchdog/vpn-watchdog.service vpn-watchdog/vpn-watchdog.timer /etc/systemd/system/
   # Edit vpn-watchdog.service: update ExecStart path and User
   sudo systemctl daemon-reload
   sudo systemctl enable --now vpn-watchdog.timer
   ```

4. Verify:
   ```bash
   systemctl status vpn-watchdog.timer
   journalctl -t vpn-watchdog --no-pager -n 10
   ```

### Flaresolverr crashes — insufficient shared memory

**Problem:** Flaresolverr's headless Chromium crashes because Docker's default `/dev/shm` is 64MB.

**Fix (already applied):** `shm_size: 2gb` and `BROWSER_TIMEOUT=80000` on the flaresolverr service.

### Mullvad port forwarding

Mullvad killed dedicated port forwarding in July 2023. qBit can only make outbound peer connections. If you need incoming peer connections for better speeds, consider ProtonVPN or AirVPN which still support port forwarding.

Port 6881 is the default torrent port and commonly blocked by ISPs. Consider changing to a random high port (45000-65000) in qBit settings and updating the port mapping in docker-compose.

### PUID/PGID — don't run as root

Set `PUID` and `PGID` to match the user that owns your media files (usually `1000`). Running as `0` (root) causes file ownership issues on shared storage (NAS, SMB mounts, etc.).

## Useful Commands

```bash
# Restart the full stack
docker compose restart

# Check VPN egress IP
docker exec gluetun wget -qO- https://ipinfo.io/ip

# Check all container health
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check qBit listening interfaces (should include VPN tunnel IP)
docker exec qbittorrent cat /config/qBittorrent/logs/qbittorrent.log | grep "Successfully listening"

# Check qBit connection status
curl -s http://localhost:8085/api/v2/transfer/info | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"status={d[\"connection_status\"]}, dht={d[\"dht_nodes\"]}")'

# Watch gluetun logs for reconnects
docker logs --tail 50 gluetun | grep -iE "connect|health|error|public.ip"

# Check VPN watchdog logs (if installed)
journalctl -t vpn-watchdog --no-pager -n 20
```

## Contributing

Contributions are welcome! Fork the repository and submit a pull request.
