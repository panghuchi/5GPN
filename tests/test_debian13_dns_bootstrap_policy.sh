#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

if [[ "${install_body}" != *'find_port53_pids()'* ]]; then
    echo "install.sh must detect port 53 without hard requiring ss before dependencies are installed." >&2
    exit 1
fi

if [[ "${install_body}" != *'ensure_system_dns()'* ]]; then
    echo "install.sh must write fallback DNS before stopping local DNS services." >&2
    exit 1
fi

if [[ "${install_body}" != *'nameserver 1.1.1.1'* || "${install_body}" != *'nameserver 8.8.8.8'* ]]; then
    echo "install.sh must provide public fallback resolvers in /etc/resolv.conf." >&2
    exit 1
fi

python3 - "${install}" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text()
main = body.split('main_install() {', 1)[1].split('\n}', 1)[0]
install_pos = main.find('install_deps')
port_pos = main.find('check_port_53')
if install_pos == -1 or port_pos == -1 or not install_pos < port_pos:
    raise SystemExit('main_install must install dependencies before checking/freeing port 53')
stop_body = body.split('stop_port53_owner() {', 1)[1].split('\n}', 1)[0]
ensure_pos = stop_body.find('ensure_system_dns')
resolved_pos = stop_body.find('systemd-resolved.service')
if ensure_pos == -1 or resolved_pos == -1 or not ensure_pos < resolved_pos:
    raise SystemExit('stop_port53_owner must ensure system DNS before stopping systemd-resolved')
PY

echo "debian13 DNS bootstrap policy OK"
