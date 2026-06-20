#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

if [[ "${install_body}" != *'download_file()'* ]]; then
    echo "install.sh must centralize remote downloads with timeout/retry handling." >&2
    exit 1
fi

if [[ "${install_body}" != *'codeload.github.com/${REPO_OWNER}/${REPO_NAME}'* ]]; then
    echo "install.sh must try codeload.github.com before the github.com archive URL." >&2
    exit 1
fi

if [[ "${install_body}" != *'falling back to raw.githubusercontent.com file download'* ]]; then
    echo "install.sh must fall back to raw.githubusercontent.com when archive downloads fail." >&2
    exit 1
fi

if [[ "${install_body}" != *'${REPO_RAW_BASE}/${file}'* ]]; then
    echo "install.sh must download required project files individually from raw.githubusercontent.com." >&2
    exit 1
fi

echo "remote bootstrap fallback policy OK"
