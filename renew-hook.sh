#!/bin/bash
# Let's Encrypt renewal hook - copy certs to mosdns-readable location and reload
set -e

# Find the most recently updated live directory
LIVE_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d | grep -v "^/etc/letsencrypt/live$" | head -n1)
if [[ -z "$LIVE_DIR" ]]; then
    echo "[!] No certificate live directory found"
    exit 1
fi

mkdir -p /etc/mosdns/certs
cp "${LIVE_DIR}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
cp "${LIVE_DIR}/privkey.pem" /etc/mosdns/certs/privkey.pem
chmod 644 /etc/mosdns/certs/fullchain.pem
chmod 600 /etc/mosdns/certs/privkey.pem

if systemctl is-active --quiet mosdns; then
    systemctl restart mosdns
fi
