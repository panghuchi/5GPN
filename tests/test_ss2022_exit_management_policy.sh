#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="$(cat "${root}/install.sh")"
readme="$(cat "${root}/README.md")"

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    [[ "${haystack}" == *"${needle}"* ]] || { echo "Missing SS2022 exit marker: ${description} (${needle})" >&2; exit 1; }
}

assert_contains "${install}" 'EXITS_DIR="${CONF_DIR}/exits"' 'exit inventory directory'
assert_contains "${install}" 'validate_exit_name()' 'exit name validation'
assert_contains "${install}" 'save_ss2022_exit()' 'SS2022 exit persistence'
assert_contains "${install}" '"type": "ss2022"' 'exit JSON type marker'
assert_contains "${install}" 'load_ss2022_exit()' 'SS2022 exit loading'
assert_contains "${install}" '.current_exit' 'current exit pointer'
assert_contains "${install}" 'list_exits()' 'exit listing command'
assert_contains "${install}" 'activate_exit()' 'exit activation function'
assert_contains "${install}" 'add_exit_command()' 'add-exit command'
assert_contains "${install}" 'Missing SS2022 exit fields' 'noninteractive add-exit validation'
assert_contains "${install}" 'set_exit_command()' 'set-exit command'
assert_contains "${install}" '--add-exit)' 'add-exit CLI dispatch'
assert_contains "${install}" '--list-exits)' 'list-exits CLI dispatch'
assert_contains "${install}" '--set-exit)' 'set-exit CLI dispatch'
assert_contains "${install}" 'render_xray_config' 'Xray config rendering is still current-exit based'
assert_contains "${install}" 'restart_egress_services()' 'switch restarts egress services'
assert_contains "${readme}" '/opt/proxy-gateway/etc/exits/*.json' 'README documents exit inventory'
assert_contains "${readme}" '/opt/proxy-gateway/etc/.current_exit' 'README documents active exit pointer'
assert_contains "${readme}" './install.sh --add-exit' 'README documents add-exit'
assert_contains "${readme}" '默认交互输入出口名' 'README documents interactive add-exit'
assert_contains "${readme}" './install.sh --set-exit' 'README documents set-exit'

echo "SS2022 exit management policy OK"
