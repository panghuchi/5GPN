#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/update-rules.sh")"

[[ "${rules}" == *'install_config()'* ]] || { echo "update-rules.sh must render mosdns config after rule updates." >&2; exit 1; }
[[ "${rules}" == *'reload_mosdns()'* ]] || { echo "update-rules.sh must restart mosdns after rule updates." >&2; exit 1; }
[[ "${rules}" == *'systemctl restart mosdns'* ]] || { echo "update-rules.sh must restart active mosdns." >&2; exit 1; }

echo "update-rules mosdns reload policy OK"
