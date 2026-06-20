#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/mosdns_config.yaml")"
race_proxy="$(cat "${root}/china-dns-race-proxy.go")"

for dns in '223.5.5.5:53' '223.6.6.6:53'; do
    [[ "${race_proxy}" == *"${dns}"* ]] || { echo "China DNS race proxy must keep AliDNS upstream ${dns}." >&2; exit 1; }
    [[ "${template}" != *"${dns}"* ]] || { echo "mosdns must not query ${dns} directly; it should use the local race proxy." >&2; exit 1; }
done
[[ "${race_proxy}" == *'1.1.1.1:53,8.8.8.8:53,22.22.22.22:53'* ]] || { echo "China DNS race proxy must include overseas fallback resolvers." >&2; exit 1; }
[[ "${template}" == *'udp://127.0.0.1:5301'* ]] || { echo "China DNS pool should route through the local race proxy." >&2; exit 1; }
[[ "${race_proxy}" == *'raceTCPDelay      = flag.Duration("tcp-delay", 150*time.Millisecond'* ]] || { echo "China DNS race proxy must retry domestic resolvers over TCP shortly after UDP stalls." >&2; exit 1; }
[[ "${race_proxy}" == *'raceFallbackDelay = flag.Duration("fallback-delay", 750*time.Millisecond'* ]] || { echo "China DNS race proxy must give domestic TCP a chance before overseas fallback." >&2; exit 1; }

echo "China DNS race upstream policy OK"
