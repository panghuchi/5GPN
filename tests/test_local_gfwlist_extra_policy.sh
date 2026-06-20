#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rules="$(cat "${root}/update-rules.sh")"
readme="$(cat "${root}/README.md")"

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    [[ "${haystack}" == *"${needle}"* ]] || { echo "Missing custom rule marker: ${description} (${needle})" >&2; exit 1; }
}
assert_contains "${rules}" 'CUSTOM_DIR="${BASE_DIR}/rules/custom"' 'custom rules directory'
assert_contains "${rules}" 'SUBS_DIR="${BASE_DIR}/subscriptions"' 'subscription URL directory'
assert_contains "${rules}" 'append_subscription_domains()' 'subscription downloader'
assert_contains "${rules}" 'proxy-urls.txt' 'proxy subscription file naming'
assert_contains "${readme}" '/etc/mosdns/rules/custom/proxy.txt' 'README custom proxy file'
assert_contains "${readme}" '/etc/mosdns/subscriptions/proxy-urls.txt' 'README proxy subscription file'

echo "custom split rule policy markers OK"
