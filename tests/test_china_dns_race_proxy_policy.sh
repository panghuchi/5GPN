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
[[ "${install}" == *'CHINA_DNS_ECS=139.226.48.0/24'* ]] || { echo "china-dns-race-proxy service must keep the old China ECS default." >&2; exit 1; }
[[ "${install}" == *'CHINA_DNS_UPSTREAMS=223.5.5.5:53,223.6.6.6:53'* ]] || { echo "china-dns-race-proxy service must default to AliDNS upstreams." >&2; exit 1; }
[[ "${install}" == *'china-dns-race-proxy.env'* ]] || { echo "china-dns-race-proxy ECS must be operator-configurable." >&2; exit 1; }
[[ "${race_proxy}" == *'net.Listen("tcp", *raceListenAddr)'* ]] || { echo "china-dns-race-proxy must accept TCP DNS queries." >&2; exit 1; }
[[ "${race_proxy}" == *'raceECS'* ]] || { echo "china-dns-race-proxy must support EDNS Client Subnet." >&2; exit 1; }
[[ "${race_proxy}" == *'addEDNSClientSubnet'* ]] || { echo "china-dns-race-proxy must inject EDNS Client Subnet into upstream queries." >&2; exit 1; }

echo "China DNS race proxy policy OK"
