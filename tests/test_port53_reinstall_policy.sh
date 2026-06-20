#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

if [[ "${install_body}" != *'find_port53_pids()'* ]]; then
    echo "install.sh must collect all port 53 listener PIDs, not only the first one." >&2
    exit 1
fi

if [[ "${install_body}" != *'wait_for_port53_free()'* ]]; then
    echo "install.sh must wait until port 53 is actually free before continuing." >&2
    exit 1
fi

if [[ "${install_body}" != *'systemctl stop dnsdist.socket dnsdist.service'* ]]; then
    echo "install.sh must stop dnsdist socket and service during reinstall cleanup." >&2
    exit 1
fi

if [[ "${install_body}" != *'kill -9 "$pid"'* ]]; then
    echo "install.sh must force-kill stale port 53 owner processes if graceful stop fails." >&2
    exit 1
fi

echo "port 53 reinstall policy OK"
