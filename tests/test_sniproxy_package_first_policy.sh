#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

if [[ "${install_body}" != *'Compiling sniproxy from source (distro packages may use incompatible builds)'* ]]; then
    echo "install.sh must build sniproxy from source by default." >&2
    exit 1
fi

if [[ "${install_body}" != *'git is required to build sniproxy from source.'* ]]; then
    echo "install.sh must fail clearly when source-build prerequisites are unavailable." >&2
    exit 1
fi

python3 - "${install}" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text()
fn = body.split('install_sniproxy() {', 1)[1].split('\n}\n\n# =============================================================================\n# quic-proxy', 1)[0]
clone_pos = fn.find('git clone --depth=1 https://github.com/dlundquist/sniproxy.git')
if 'apt-get install -y -qq sniproxy' in fn or '$PKG_MGR install -y -q sniproxy' in fn:
    raise SystemExit('install_sniproxy must not install distro sniproxy packages by default')
if clone_pos == -1:
    raise SystemExit('install_sniproxy must clone upstream sniproxy source')
if '/usr/local/sbin/sniproxy' not in fn:
    raise SystemExit('install_sniproxy must use the source-installed /usr/local/sbin/sniproxy')
PY

echo "sniproxy source-first policy OK"
