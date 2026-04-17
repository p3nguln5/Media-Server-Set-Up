#!/bin/bash
# vpn-watchdog.sh — restart qBittorrent when gluetun reconnects to a new VPN server
# Compares gluetun's current public IP to qBit's last-detected external IP.
# If they differ, qBit's sockets are stale and it needs a restart.
#
# EDIT THESE VARIABLES for your setup:

COMPOSE_DIR=/path/to/your/compose/dir    # <-- change to your docker-compose directory
COOKIE_JAR=/tmp/qbt-watchdog-cookies
QBIT_PORT=8085                           # <-- change if different
QBIT_USER=admin                          # <-- your qBit WebUI username
QBIT_PASS='changeme'                     # <-- your qBit WebUI password
LOG_TAG=vpn-watchdog

log() { logger -t "$LOG_TAG" "$1"; }

# Get gluetun's current public IP (curl runs inside qbit container which shares gluetun's network)
GLUETUN_IP=$(docker exec qbittorrent curl -sf --max-time 5 https://am.i.mullvad.net/ip 2>/dev/null | tr -d '[:space:]')
if [[ -z "$GLUETUN_IP" ]]; then
    # Fallback to a generic IP check service (works with any VPN provider)
    GLUETUN_IP=$(docker exec qbittorrent curl -sf --max-time 5 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]')
fi
if [[ -z "$GLUETUN_IP" ]]; then
    log "WARN: could not reach IP check service — VPN may be down, skipping"
    exit 0
fi

# Get qBit's last-detected external IP via API
curl -sf -c "$COOKIE_JAR" "http://localhost:${QBIT_PORT}/api/v2/auth/login" \
    --data-urlencode "username=${QBIT_USER}" \
    --data-urlencode "password=${QBIT_PASS}" > /dev/null 2>&1

QBIT_IP=$(curl -sf -b "$COOKIE_JAR" "http://localhost:${QBIT_PORT}/api/v2/transfer/info" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_external_address_v4",""))' 2>/dev/null)

if [[ -z "$QBIT_IP" ]]; then
    log "WARN: could not query qBit API — container may be restarting, skipping"
    exit 0
fi

# Compare
if [[ "$GLUETUN_IP" != "$QBIT_IP" ]]; then
    log "IP mismatch detected — gluetun=$GLUETUN_IP qbit=$QBIT_IP — restarting qbittorrent"
    cd "$COMPOSE_DIR" && docker compose restart qbittorrent
    log "qbittorrent restarted"
else
    log "IPs match ($GLUETUN_IP) — no action needed"
fi

rm -f "$COOKIE_JAR"
