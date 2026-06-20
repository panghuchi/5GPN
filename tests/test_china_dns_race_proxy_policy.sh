#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/mosdns_config.yaml")"
install="$(cat "${root}/install.sh")"
race_proxy="$(cat "${root}/china-dns-race-proxy.go")"

[[ "${template}" == *'udp://127.0.0.1:5301'* ]] || { echo "ChinaList traffic must be sent to the local China DNS race proxy." >&2; exit 1; }
[[ "${install}" == *'install_china_dns_race_proxy()'* ]] || { echo "install.sh must install the China DNS race proxy service." >&2; exit 1; }
[[ "${install}" == *'china-dns-race-proxy.service'* ]] || { echo "install.sh must create china-dns-race-proxy.service." >&2; exit 1; }
[[ "${install}" == *'systemctl restart china-dns-race-proxy'* ]] || { echo "install.sh must start china-dns-race-proxy before mosdns." >&2; exit 1; }
[[ "${install}" == *'for svc in mosdns sniproxy quic-proxy china-dns-race-proxy'* ]] || { echo "install.sh --status must include china-dns-race-proxy." >&2; exit 1; }
[[ "${install}" == *'ExecStart=/opt/proxy-gateway/bin/china-dns-race-proxy -l 127.0.0.1:5301'* ]] || { echo "china-dns-race-proxy must listen on the mosdns China upstream address." >&2; exit 1; }
[[ "${race_proxy}" == *'net.Listen("tcp", *raceListenAddr)'* ]] || { echo "china-dns-race-proxy must accept TCP DNS queries." >&2; exit 1; }

echo "China DNS race proxy policy OK"
