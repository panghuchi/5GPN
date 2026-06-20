#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/mosdns_config.yaml")"

[[ "${template}" != *'black_hole ::1'* ]] || { echo "GFWList AAAA queries must not be spoofed to ::1." >&2; exit 1; }
[[ "${template}" == *'matches: qtype 28'* ]] || { echo "AAAA queries should return NOERROR/NODATA globally so clients fall back to IPv4 A records." >&2; exit 1; }

echo "GFWList AAAA policy OK"
