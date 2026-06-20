#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install_body="$(cat "${root}/install.sh")"

if [[ "${install_body}" != *'copy_mosdns_cert()'* ]]; then
    echo "install.sh must use a shared helper for copying mosdns certificates." >&2
    exit 1
fi
if [[ "${install_body}" != *'Existing Let'"'"'s Encrypt certificate found for $DOMAIN; reusing it for installation.'* ]]; then
    echo "install.sh must reuse existing Let's Encrypt certificates during normal installation." >&2
    exit 1
fi
install_cert_body="$(python3 - "${root}/install.sh" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text()
print(body.split('install_cert() {', 1)[1].split('\n}\n\n# =============================================================================\n# sniproxy', 1)[0])
PY
)"
if [[ "${install_cert_body}" == *'--force-renewal'* ]]; then
    echo "normal install_cert must not force-renew existing certificates." >&2
    exit 1
fi
echo "certificate reuse policy OK"
