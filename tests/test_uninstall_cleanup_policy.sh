#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="$(cat "${root}/install.sh")"

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    [[ "${haystack}" == *"${needle}"* ]] || { echo "Missing uninstall cleanup marker: ${description} (${needle})" >&2; exit 1; }
}

assert_contains "${install}" 'systemctl stop update-mosdns-rules.timer update-mosdns-rules.service' 'stops rule update timer'
assert_contains "${install}" 'systemctl stop dnsdist mosdns sniproxy 5gpn-tcp-proxy quic-proxy china-dns-race-proxy' 'stops 5GPN services'
assert_contains "${install}" 'systemctl stop xray' 'stops managed Xray'
assert_contains "${install}" '.xray_installed_by_5gpn' 'tracks Xray installed by 5GPN'
assert_contains "${install}" 'rm -f /etc/systemd/system/mosdns.service' 'removes mosdns unit'
assert_contains "${install}" 'rm -f /etc/systemd/system/update-mosdns-rules.timer' 'removes timer unit'
assert_contains "${install}" 'rm -rf "$BASE_DIR"' 'removes proxy gateway directory'
assert_contains "${install}" 'rm -rf /etc/mosdns /etc/dnsdist' 'removes DNS config directories'
assert_contains "${install}" 'rm -f /usr/local/bin/update-mosdns-rules.sh' 'removes rule updater'
assert_contains "${install}" 'rm -f /usr/local/bin/proxy-gateway-open-cert-http.sh' 'removes cert pre-hook helper'
assert_contains "${install}" 'rm -f /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh' 'removes certbot pre-hook'
assert_contains "${install}" 'rm -f /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh' 'removes certbot post-hook'
assert_contains "${install}" 'rm -f /etc/sysctl.d/99-proxy-gateway.conf' 'removes sysctl tuning'
assert_contains "${install}" 'rm -f /etc/modules-load.d/proxy-gateway-net.conf' 'removes module load config'
assert_contains "${install}" 'rm -f /etc/profile.d/go.sh' 'removes Go profile script'
assert_contains "${install}" 'rm -f /etc/systemd/journald.conf.d/99-proxy-gateway.conf' 'removes journald tuning'
assert_contains "${install}" 'rm -f /etc/ssh/sshd_config.d/99-5gpn-port.conf' 'removes SSH drop-in'
assert_contains "${install}" 'rm -f /etc/nftables.conf' 'removes generated nftables config'
assert_contains "${install}" 'rm -f /usr/local/bin/xray' 'removes Xray binary when installed by 5GPN'
assert_contains "${install}" 'rm -rf /usr/local/share/xray /usr/local/etc/xray /var/log/xray' 'removes Xray directories when installed by 5GPN'
assert_contains "${install}" "sed -i '/# proxy-gateway-limits/,+4d' /etc/security/limits.conf" 'removes limits marker block'
assert_contains "${install}" 'nft flush ruleset' 'flushes active nft rules'
assert_contains "${install}" 'Let'\''s Encrypt certificates in /etc/letsencrypt are kept' 'documents certificate preservation'

echo "uninstall cleanup policy OK"
