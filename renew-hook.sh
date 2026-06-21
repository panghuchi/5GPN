#!/bin/bash
# Let's Encrypt renewal hook - copy certs to mosdns/dnsdist-readable locations and reload
set -e

# Find the most recently updated live directory
LIVE_DIR=$(find /etc/letsencrypt/live -maxdepth 1 -type d | grep -v "^/etc/letsencrypt/live$" | head -n1)
if [[ -z "$LIVE_DIR" ]]; then
    echo "[!] No certificate live directory found"
    exit 1
fi

mkdir -p /etc/mosdns/certs /etc/dnsdist/certs
cp "${LIVE_DIR}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
cp "${LIVE_DIR}/privkey.pem" /etc/mosdns/certs/privkey.pem
cp "${LIVE_DIR}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
cp "${LIVE_DIR}/privkey.pem" /etc/dnsdist/certs/privkey.pem
chmod 644 /etc/mosdns/certs/fullchain.pem
chmod 600 /etc/mosdns/certs/privkey.pem
chmod 644 /etc/dnsdist/certs/fullchain.pem
chmod 640 /etc/dnsdist/certs/privkey.pem
if id _dnsdist >/dev/null 2>&1; then
    chown -R _dnsdist:_dnsdist /etc/dnsdist/certs
elif id dnsdist >/dev/null 2>&1; then
    chown -R dnsdist:dnsdist /etc/dnsdist/certs
fi

if systemctl is-active --quiet mosdns; then
    systemctl restart mosdns
fi
if systemctl is-active --quiet dnsdist; then
    systemctl reload dnsdist 2>/dev/null || systemctl restart dnsdist
fi
