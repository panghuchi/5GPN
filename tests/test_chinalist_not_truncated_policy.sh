#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/update-rules.sh")"
chinalist_block="$(sed -n '/build_chinalist()/,/^}/p' "${root}/update-rules.sh")"

[[ "${rules}" != *'max=30000'* ]] || { echo "ChinaList must not be capped at 30000 entries." >&2; exit 1; }
[[ "${chinalist_block}" != *'break'* ]] || { echo "ChinaList parsing must not stop early on a fixed max count." >&2; exit 1; }
[[ "${rules}" == *'server=/\K'* ]] || { echo "ChinaList parser must extract all accelerated-domains entries." >&2; exit 1; }
[[ "${rules}" == *'chinalist.txt'* ]] || { echo "mosdns should load generated chinalist.txt." >&2; exit 1; }
[[ "${rules}" == *'CHINALIST_FALLBACK_URL'* ]] || { echo "ChinaList download must have a fallback source." >&2; exit 1; }
[[ "${rules}" == *'--max-time "$DOWNLOAD_MAX_TIME"'* ]] || { echo "Rule downloads must have a hard max-time timeout." >&2; exit 1; }
[[ "${rules}" == *'RULE_DOWNLOAD_TOOL="${RULE_DOWNLOAD_TOOL:-auto}"'* ]] || { echo "Rule downloader must support selecting wget/curl." >&2; exit 1; }
[[ "${rules}" == *'tools=(wget curl)'* ]] || { echo "Rule downloader auto mode must try wget before curl." >&2; exit 1; }
[[ "${rules}" == *'download_rules_file "$raw" "$CHINALIST_URL" "$CHINALIST_FALLBACK_URL"'* ]] || { echo "ChinaList must use the central timeout/fallback downloader." >&2; exit 1; }

echo "ChinaList is not truncated"
