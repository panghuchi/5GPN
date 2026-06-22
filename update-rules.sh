#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/etc/mosdns"
DNSDIST_DIR="/etc/dnsdist"
RULES_DIR="${BASE_DIR}/rules"
SUBS_DIR="${BASE_DIR}/subscriptions"
CUSTOM_DIR="${BASE_DIR}/rules/custom"
CONFIG_TEMPLATE="${BASE_DIR}/config.yaml.template"
CONFIG_FILE="${BASE_DIR}/config.yaml"
DNSDIST_TEMPLATE="${DNSDIST_DIR}/dnsdist.conf.template"
DNSDIST_CONFIG="${DNSDIST_DIR}/dnsdist.conf"
GFWLIST_URL="${GFWLIST_URL:-https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt}"
CHINALIST_URL="${CHINALIST_URL:-https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf}"
GFWLIST_FALLBACK_URL="${GFWLIST_FALLBACK_URL:-https://cdn.jsdelivr.net/gh/gfwlist/gfwlist@master/gfwlist.txt}"
CHINALIST_FALLBACK_URL="${CHINALIST_FALLBACK_URL:-https://cdn.jsdelivr.net/gh/felixonmars/dnsmasq-china-list@master/accelerated-domains.china.conf}"
DOWNLOAD_CONNECT_TIMEOUT="${DOWNLOAD_CONNECT_TIMEOUT:-8}"
DOWNLOAD_MAX_TIME="${DOWNLOAD_MAX_TIME:-30}"
RULE_DOWNLOAD_TOOL="${RULE_DOWNLOAD_TOOL:-auto}"
DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_PUBLIC_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8")
DEFAULT_NPN_CLIENT_CIDRS=("172.22.0.0/16")
SUBSCRIPTION_FILES=("proxy-urls.txt" "direct-urls.txt" "china-urls.txt" "reject-urls.txt")

log() { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[!] $*" >&2; }

download_with_tool() {
    local tool="$1"
    local url="$2"
    local output="$3"

    case "$tool" in
        wget)
            command -v wget >/dev/null 2>&1 || return 127
            wget -q \
                --timeout="$DOWNLOAD_CONNECT_TIMEOUT" \
                --read-timeout="$DOWNLOAD_MAX_TIME" \
                --tries=2 \
                -O "$output" \
                "$url"
            ;;
        curl)
            command -v curl >/dev/null 2>&1 || return 127
            curl -fsSL \
                --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
                --max-time "$DOWNLOAD_MAX_TIME" \
                --retry 1 \
                --retry-delay 1 \
                "$url" -o "$output"
            ;;
        *)
            return 127
            ;;
    esac
}

download_rules_file() {
    local output="$1"
    shift

    local tools=()
    case "$RULE_DOWNLOAD_TOOL" in
        wget) tools=(wget) ;;
        curl) tools=(curl) ;;
        auto) tools=(wget curl) ;;
        *)
            warn "Unknown RULE_DOWNLOAD_TOOL=${RULE_DOWNLOAD_TOOL}; using auto"
            tools=(wget curl)
            ;;
    esac

    local url tool
    for url in "$@"; do
        [[ -z "$url" ]] && continue
        log "Trying rule source: $url"
        for tool in "${tools[@]}"; do
            log "Downloading with ${tool}..."
            if download_with_tool "$tool" "$url" "$output"; then
                log "Downloaded rule source with ${tool}"
                return 0
            fi
            warn "${tool} failed or timed out for: $url"
        done
        warn "Rule source unavailable or too slow: $url"
    done

    return 1
}

trim_domain() {
    local domain="$1"
    domain="${domain%%#*}"
    domain="${domain%%,*}"
    domain="${domain%%/*}"
    domain="${domain#||}"
    domain="${domain#\.}"
    domain="${domain#\*.}"
    domain="${domain#www.}"
    domain="${domain%\^}"
    domain="${domain%.}"
    domain="$(echo "$domain" | tr -d '\r' | xargs 2>/dev/null || true)"
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$ ]] || return 1
    printf '%s\n' "$domain"
}

normalize_domain_file() {
    local input="$1"
    local output="$2"

    awk '
        function trim(s) {
            gsub(/\r/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
        }
        function emit(raw, value) {
            value = tolower(trim(raw))
            sub(/^'\''/, "", value)
            sub(/'\''$/, "", value)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            sub(/^\+\./, "", value)
            sub(/^\|\|/, "", value)
            sub(/^\*\./, "", value)
            sub(/^\./, "", value)
            sub(/^www\./, "", value)
            sub(/\^$/, "", value)
            sub(/\.$/, "", value)
            if (value ~ /^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$/) {
                print value
            }
        }
        {
            sub(/\r$/, "")
            sub(/#.*/, "")
            line = trim($0)
            if (line == "" || line ~ /^!/) next

            if (line ~ /^\|\|/) {
                sub(/^\|\|/, "", line)
                sub(/\^.*/, "", line)
                sub(/\/.*/, "", line)
                emit(line)
                next
            }

            split(line, parts, ",")
            kind = toupper(trim(parts[1]))
            sub(/^- */, "", kind)
            if (kind == "DOMAIN" || kind == "DOMAIN-SUFFIX" || kind == "DOMAIN-KEYWORD" || kind == "HOST" || kind == "HOST-SUFFIX") {
                emit(parts[2])
                next
            }

            if (line ~ /^server=\// || line ~ /^address=\// || line ~ /^ipset=\// || line ~ /^nftset=\//) {
                split(line, dnsmasq, "/")
                emit(dnsmasq[2])
                next
            }

            if (line ~ /^\[/) next

            sub(/\/.*/, "", line)
            emit(line)
        }
    ' "$input" >> "$output"
}

render_mosdns_upstreams() {
    local input="${1:-}"
    local dns_list=()
    local item
    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi
    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid upstream address: $item"
            continue
        fi
        printf '        - addr: "udp://%s:53"\n' "$item"
    done
}

render_mosdns_client_cidrs() {
    local input="${1:-}"
    local cidr_list=()
    local cidr has_loopback=0
    if [[ -z "$input" ]]; then
        cidr_list=("${DEFAULT_NPN_CLIENT_CIDRS[@]}")
    else
        input="${input//,/ }"
        read -r -a cidr_list <<< "$input"
    fi
    for cidr in "${cidr_list[@]}"; do
        [[ -z "$cidr" ]] && continue
        if [[ ! "$cidr" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
            warn "Skipping invalid NPN client CIDR: $cidr"
            continue
        fi
        [[ "$cidr" == "127.0.0.1/32" ]] && has_loopback=1
        printf '        - "%s"\n' "$cidr"
    done
    if [[ "$has_loopback" == "0" ]]; then
        printf '        - "127.0.0.1/32"\n'
    fi
}

render_dnsdist_client_cidrs() {
    local input="${1:-}"
    local cidr_list=()
    local cidr first=1
    if [[ -z "$input" ]]; then
        cidr_list=("${DEFAULT_NPN_CLIENT_CIDRS[@]}")
    else
        input="${input//,/ }"
        read -r -a cidr_list <<< "$input"
    fi
    for cidr in "${cidr_list[@]}"; do
        [[ -z "$cidr" ]] && continue
        if [[ ! "$cidr" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]; then
            warn "Skipping invalid dnsdist NPN client CIDR: $cidr"
            continue
        fi
        if [[ "$first" == "0" ]]; then
            printf ', '
        fi
        printf '"%s"' "$cidr"
        first=0
    done
    [[ "$first" == "0" ]] || printf '"172.22.0.0/16"'
}

dns_query_log_enabled() {
    local value="${DNS_QUERY_LOG:-0}"
    [[ -f "${BASE_DIR}/.query_log" ]] && value="$(cat "${BASE_DIR}/.query_log" 2>/dev/null || echo "$value")"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

render_mosdns_query_log_rule() {
    local label="$1"
    if dns_query_log_enabled; then
        printf '      - exec: query_summary %s\n' "$label"
    fi
}

append_subscription_domains() {
    local category="$1"
    local output="$2"
    local urls_file="${SUBS_DIR}/${category}-urls.txt"
    [[ -f "$urls_file" ]] || return 0

    local url tmp normalized before after count=0
    while IFS= read -r url || [[ -n "$url" ]]; do
        url="${url%%#*}"
        url="$(echo "$url" | xargs 2>/dev/null || true)"
        [[ -z "$url" ]] && continue
        tmp="$(mktemp)"
        normalized="$(mktemp)"
        if download_rules_file "$tmp" "$url"; then
            before=$(wc -l < "$output" 2>/dev/null || echo 0)
            normalize_domain_file "$tmp" "$normalized"
            cat "$normalized" >> "$output"
            after=$(wc -l < "$output" 2>/dev/null || echo 0)
            count=$((count + after - before))
        else
            warn "Failed to download ${category} subscription: $url"
        fi
        rm -f "$tmp" "$normalized"
    done < "$urls_file"
    log "${category} subscription domains appended: ${count}"
}

append_local_domains() {
    local input="$1"
    local output="$2"
    [[ -f "$input" ]] || return 0
    local normalized count=0
    normalized="$(mktemp)"
    normalize_domain_file "$input" "$normalized"
    count=$(wc -l < "$normalized" 2>/dev/null || echo 0)
    cat "$normalized" >> "$output"
    rm -f "$normalized"
    log "$(basename "$input") local domains appended: ${count}"
}

build_gfwlist() {
    local raw decoded output="$1"
    raw="$(mktemp)"; decoded="$(mktemp)"
    : > "$output"
    log "Downloading GFWList..."
    if download_rules_file "$raw" "$GFWLIST_URL" "$GFWLIST_FALLBACK_URL" && \
       (base64 -d "$raw" > "$decoded" 2>/dev/null || base64 -d -i "$raw" > "$decoded" 2>/dev/null || openssl enc -base64 -d -in "$raw" > "$decoded" 2>/dev/null); then
        local line domain count=0 max=20000
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*[!\[] ]] && continue
            [[ -z "$line" ]] && continue
            line="${line#||}"
            line="${line#|http://}"
            line="${line#|https://}"
            line="${line#\.}"
            line="${line#\*.}"
            line="${line%%^*}"
            line="${line%%/*}"
            if domain=$(trim_domain "$line"); then
                echo "$domain" >> "$output"
                count=$((count + 1))
                [[ $count -ge $max ]] && break
            fi
        done < "$decoded"
        sort -u -o "$output" "$output"
        log "GFWList generated: $(wc -l < "$output") domains"
    else
        warn "GFWList download/decode failed; keeping empty generated list"
    fi
    rm -f "$raw" "$decoded"
}

build_chinalist() {
    local raw output="$1"
    raw="$(mktemp)"
    : > "$output"
    log "Downloading ChinaList..."
    if download_rules_file "$raw" "$CHINALIST_URL" "$CHINALIST_FALLBACK_URL"; then
        awk -F/ '/^server=\/[^/]+\// { print $2 }' "$raw" | \
            awk '
                {
                    sub(/\r$/, "")
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                    sub(/^\*\./, "")
                    sub(/^\./, "")
                    sub(/^www\./, "")
                    sub(/\.$/, "")
                    if ($0 ~ /^[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)+$/) {
                        print tolower($0)
                    }
                }
            ' | sort -u > "$output"
        log "ChinaList generated: $(wc -l < "$output") domains"
    else
        warn "ChinaList download failed; keeping empty generated list"
    fi
    rm -f "$raw"
}

install_config() {
    [[ -f "$CONFIG_TEMPLATE" ]] || { warn "Config template not found: $CONFIG_TEMPLATE"; exit 1; }
    local server_ip npn_client_cidrs_raw npn_client_cidrs private_dns public_dns private_upstreams public_upstreams private_query_log_rule public_query_log_rule
    server_ip=$(cat "${BASE_DIR}/.public_ip" 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "127.0.0.1")
    npn_client_cidrs_raw=$(cat "${BASE_DIR}/.npn_client_cidrs" 2>/dev/null || echo "${DEFAULT_NPN_CLIENT_CIDRS[*]}")
    private_dns=$(cat "${BASE_DIR}/.overseas_private_dns" 2>/dev/null || cat "${BASE_DIR}/.overseas_dns" 2>/dev/null || echo "${DEFAULT_OVERSEAS_DNS[*]}")
    public_dns=$(cat "${BASE_DIR}/.overseas_public_dns" 2>/dev/null || echo "${DEFAULT_PUBLIC_OVERSEAS_DNS[*]}")
    npn_client_cidrs=$(render_mosdns_client_cidrs "$npn_client_cidrs_raw")
    private_upstreams=$(render_mosdns_upstreams "$private_dns")
    public_upstreams=$(render_mosdns_upstreams "$public_dns")
    private_query_log_rule=$(render_mosdns_query_log_rule "5gpn-private")
    public_query_log_rule=$(render_mosdns_query_log_rule "5gpn-public")

    python3 - "$CONFIG_TEMPLATE" "$server_ip" "$npn_client_cidrs" "$private_upstreams" "$public_upstreams" "$private_query_log_rule" "$public_query_log_rule" "$CONFIG_FILE" <<'PYEOF'
import sys
src, server_ip, npn_client_cidrs, private_upstreams, public_upstreams, private_query_log_rule, public_query_log_rule, dst = sys.argv[1:9]
with open(src, 'r', encoding='utf-8') as f:
    content = f.read()
content = content.replace('\ninclude: []\n', '\n')
content = content.replace('__SERVER_IP__', server_ip)
content = content.replace('__NPN_CLIENT_CIDRS__', npn_client_cidrs.rstrip() or '        - "172.22.0.0/16"\n        - "127.0.0.1/32"')
content = content.replace('__PRIVATE_OVERSEAS_UPSTREAMS__', private_upstreams.rstrip() or '        - addr: "udp://1.1.1.1:53"')
content = content.replace('__PUBLIC_OVERSEAS_UPSTREAMS__', public_upstreams.rstrip() or '        - addr: "udp://1.1.1.1:53"')
content = content.replace('__PRIVATE_QUERY_LOG_RULE__', private_query_log_rule.rstrip())
content = content.replace('__PUBLIC_QUERY_LOG_RULE__', public_query_log_rule.rstrip())
with open(dst, 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
    log "mosdns config rendered: ${CONFIG_FILE}"
}

install_dnsdist_config() {
    [[ -f "$DNSDIST_TEMPLATE" ]] || return 0
    local npn_client_cidrs_raw npn_client_cidrs_lua
    npn_client_cidrs_raw=$(cat "${BASE_DIR}/.npn_client_cidrs" 2>/dev/null || echo "${DEFAULT_NPN_CLIENT_CIDRS[*]}")
    npn_client_cidrs_lua=$(render_dnsdist_client_cidrs "$npn_client_cidrs_raw")
    python3 - "$DNSDIST_TEMPLATE" "$npn_client_cidrs_lua" "$DNSDIST_CONFIG" <<'PYEOF'
import sys
src, npn_client_cidrs_lua, dst = sys.argv[1:4]
with open(src, 'r', encoding='utf-8') as f:
    content = f.read()
content = content.replace('__NPN_CLIENT_CIDRS_LUA__', npn_client_cidrs_lua)
with open(dst, 'w', encoding='utf-8') as f:
    f.write(content)
PYEOF
    if command -v dnsdist >/dev/null 2>&1; then
        dnsdist --check-config -C "$DNSDIST_CONFIG" >/dev/null 2>&1 || {
            warn "Generated dnsdist config failed validation; keeping current frontend state"
            return 1
        }
    fi
    log "dnsdist config rendered: ${DNSDIST_CONFIG}"
}

reload_mosdns() {
    if systemctl is-active --quiet mosdns 2>/dev/null; then
        systemctl restart mosdns
        log "mosdns restarted"
    else
        systemctl start mosdns 2>/dev/null || true
        log "mosdns start requested"
    fi
    if systemctl is-active --quiet dnsdist 2>/dev/null; then
        systemctl reload dnsdist 2>/dev/null || systemctl restart dnsdist 2>/dev/null || true
        log "dnsdist frontend refreshed"
    fi
}

main() {
    log "Starting mosdns rule update..."
    mkdir -p "$RULES_DIR" "$SUBS_DIR" "$CUSTOM_DIR"

    for category in proxy direct china reject; do
        touch "${CUSTOM_DIR}/${category}.txt"
    done
    for file in "${SUBSCRIPTION_FILES[@]}"; do
        touch "${SUBS_DIR}/${file}"
    done
    touch "${RULES_DIR}/hosts.txt"

    build_gfwlist "${RULES_DIR}/gfwlist.txt"
    build_chinalist "${RULES_DIR}/chinalist.txt"

    for category in proxy direct china reject; do
        tmp="$(mktemp)"
        append_local_domains "${CUSTOM_DIR}/${category}.txt" "$tmp"
        append_subscription_domains "$category" "$tmp"
        sort -u "$tmp" > "${RULES_DIR}/${category}-domains.txt"
        rm -f "$tmp"
        log "${category}-domains.txt total: $(wc -l < "${RULES_DIR}/${category}-domains.txt") domains"
    done

    install_config
    install_dnsdist_config || true
    reload_mosdns
    log "Rule update completed."
}

main "$@"
