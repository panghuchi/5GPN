#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/mosdns_config.yaml")"

[[ "${template}" == *'matches: qtype 28'* ]] || { echo "mosdns must return NOERROR/NODATA for all AAAA queries so clients only use IPv4." >&2; exit 1; }
[[ "${template}" != *'black_hole ::1'* ]] || { echo "mosdns must not spoof IPv6 loopback addresses." >&2; exit 1; }

echo "IPv4-only DNS policy OK"
