#!/usr/bin/env bash
#
# install.sh - High-performance transparent proxy + Smart DNS (DoT) one-click installer
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12/13, CentOS 7/8/9 Stream,
#           Rocky Linux 8/9, AlmaLinux 8/9, RHEL 8/9, Fedora 39+
#

set -euo pipefail

# =============================================================================
# Configurable defaults
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="/opt/proxy-gateway"
CONF_DIR="${BASE_DIR}/etc"
LOG_DIR="${BASE_DIR}/log"
SRC_DIR="${BASE_DIR}/src"
WWW_DIR="${BASE_DIR}/www"
GFWLIST_URL="https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"
CHINALIST_URL="https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf"
DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")
DEFAULT_PUBLIC_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8")
DEFAULT_NPN_CLIENT_CIDRS=("172.22.0.0/16")
MOSDNS_VERSION="${MOSDNS_VERSION:-latest}"
SSH_PORT_CONFIGURED="${SSH_PORT:-}"
SSH_PORT="${SSH_PORT_CONFIGURED:-22}"
NPN_CLIENT_CIDRS="${NPN_CLIENT_CIDRS:-}"
EGRESS_MODE="${EGRESS_MODE:-direct}"
EGRESS_SOCKS5_ADDR="${EGRESS_SOCKS5_ADDR:-127.0.0.1:1080}"
EGRESS_SOCKS5_USERNAME="${EGRESS_SOCKS5_USERNAME:-}"
EGRESS_SOCKS5_PASSWORD="${EGRESS_SOCKS5_PASSWORD:-}"
XRAY_INSTALL="${XRAY_INSTALL:-}"
SS2022_ADDRESS="${SS2022_ADDRESS:-}"
SS2022_PORT="${SS2022_PORT:-}"
SS2022_METHOD="${SS2022_METHOD:-}"
SS2022_PASSWORD="${SS2022_PASSWORD:-}"

REPO_OWNER="${REPO_OWNER:-panghuchi}"
REPO_NAME="${REPO_NAME:-5GPN}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
REQUIRED_PROJECT_FILES=(
    "quic-proxy.go"
    "5gpn-tcp-proxy.go"
    "china-dns-race-proxy.go"
    "dnsdist.conf.template"
    "mosdns_config.yaml"
    "sniproxy.conf"
    "renew-hook.sh"
    "update-rules.sh"
)

# =============================================================================
# Colors
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

banner() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  5GPN Edge Gateway Installer${NC}"
    echo -e "${BOLD}${CYAN}  Smart DNS + TCP SNI Proxy + QUIC/HTTP3 Proxy${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""
}

phase() {
    echo ""
    echo -e "${BOLD}${CYAN}>>> $*${NC}"
}

note() {
    echo -e "${CYAN}[NOTE]${NC} $*"
}

run_quiet() {
    local description="$1"
    shift

    info "$description"
    if "$@" >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1; then
        return 0
    fi

    err "Failed: $description"
    err "See log: ${INSTALL_LOG:-/tmp/5gpn-install.log}"
    return 1
}

setup_install_log() {
    mkdir -p "$LOG_DIR"
    INSTALL_LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
    touch "$INSTALL_LOG"
    # Keep a full local transcript for later troubleshooting while still
    # streaming progress to the terminal.
    exec > >(tee -a "$INSTALL_LOG") 2>&1
    info "Install log: $INSTALL_LOG"
}

render_overseas_dns_servers() {
    local input="${1:-}"
    local pool="${2:-overseas}"
    local prefix="${3:-overseas}"
    local dns_list=()
    local item order=1 name

    if [[ -z "$input" ]]; then
        dns_list=("${DEFAULT_OVERSEAS_DNS[@]}")
    else
        input="${input//,/ }"
        read -r -a dns_list <<< "$input"
    fi

    for item in "${dns_list[@]}"; do
        [[ -z "$item" ]] && continue
        if [[ ! "$item" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            warn "Skipping invalid overseas DNS address: $item"
            continue
        fi
        name="${prefix}${order}"
        printf 'newServer({address="%s:53", pool="%s", name="%s", order=%d, useClientSubnet=true})\n' "$item" "$pool" "$name" "$order"
        order=$((order + 1))
    done
}

render_sniproxy_dns_nameservers() {
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
            warn "Skipping invalid sniproxy DNS address: $item"
            continue
        fi
        printf '    nameserver %s\n' "$item"
    done
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
            warn "Skipping invalid mosdns upstream address: $item"
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
    [[ -f /etc/mosdns/.query_log ]] && value="$(cat /etc/mosdns/.query_log 2>/dev/null || echo "$value")"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

render_mosdns_query_log_rule() {
    local label="$1"
    if dns_query_log_enabled; then
        printf '      - exec: query_summary %s\n' "$label"
    fi
}

configure_overseas_dns() {
    # DNS is the control plane of this gateway. Keep private-client upstreams,
    # public DoT upstreams, and sniproxy resolver upstreams separate so 5G NPN
    # clients can use a stricter policy without changing public DoT behavior.
    local legacy="${OVERSEAS_DNS:-}"
    local private_selected="${PRIVATE_OVERSEAS_DNS:-$legacy}"
    local public_selected="${PUBLIC_OVERSEAS_DNS:-}"
    local sniproxy_selected="${SNIPROXY_DNS:-}"

    if [[ -z "$private_selected" && -t 0 ]]; then
        echo ""
        read -r -p "Private overseas DNS upstreams [1.1.1.1,8.8.8.8,9.9.9.9]: " private_selected
    fi
    if [[ -z "$public_selected" && -t 0 ]]; then
        read -r -p "Public overseas DNS upstreams [1.1.1.1,8.8.8.8]: " public_selected
    fi
    if [[ -z "$sniproxy_selected" && -t 0 ]]; then
        read -r -p "sniproxy resolver upstreams [same as private overseas DNS]: " sniproxy_selected
    fi

    if [[ -z "$private_selected" ]]; then
        private_selected="${DEFAULT_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$public_selected" ]]; then
        public_selected="${DEFAULT_PUBLIC_OVERSEAS_DNS[*]}"
    fi
    if [[ -z "$sniproxy_selected" ]]; then
        sniproxy_selected="$private_selected"
    fi

    OVERSEAS_DNS="$private_selected"
    PRIVATE_OVERSEAS_DNS="$private_selected"
    PUBLIC_OVERSEAS_DNS="$public_selected"
    SNIPROXY_DNS="$sniproxy_selected"

    mkdir -p "$CONF_DIR"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_dns"
    echo "$PRIVATE_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_private_dns"
    echo "$PUBLIC_OVERSEAS_DNS" > "${CONF_DIR}/.overseas_public_dns"
    echo "$SNIPROXY_DNS" > "${CONF_DIR}/.sniproxy_dns"
    info "Private overseas DNS upstreams: $PRIVATE_OVERSEAS_DNS"
    info "Public overseas DNS upstreams: $PUBLIC_OVERSEAS_DNS"
    info "sniproxy resolver upstreams: $SNIPROXY_DNS"
    note "Resolver policy saved under ${CONF_DIR}; rule updates will reuse these values."
}

configure_npn_client_cidrs() {
    local selected="${NPN_CLIENT_CIDRS:-}"

    if [[ -z "$selected" && -t 0 ]]; then
        echo ""
        read -r -p "NPN/private DNS client CIDRs [172.22.0.0/16]: " selected
    fi
    if [[ -z "$selected" ]]; then
        selected="${DEFAULT_NPN_CLIENT_CIDRS[*]}"
    fi

    NPN_CLIENT_CIDRS="$selected"
    mkdir -p "$CONF_DIR"
    echo "$NPN_CLIENT_CIDRS" > "${CONF_DIR}/.npn_client_cidrs"
    info "NPN/private DNS client CIDRs: $NPN_CLIENT_CIDRS"
    note "If DNS queries arrive from another carrier/NAT CIDR, add it here so mosdns returns the VPS IP."
}

normalize_egress_mode() {
    local value="${1:-direct}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    value="${value//[[:space:]]/}"
    [[ -z "$value" ]] && value="direct"
    case "$value" in
        1) value="direct" ;;
        2) value="socks5" ;;
    esac
    printf '%s\n' "$value"
}

validate_socks5_addr() {
    local value="$1"
    local host port

    [[ "$value" == *:* ]] || return 1
    host="${value%:*}"
    port="${value##*:}"
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
}

normalize_yes_no() {
    local value="${1:-no}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    value="${value//[[:space:]]/}"
    case "$value" in
        y|yes|1|true|on) value="yes" ;;
        n|no|0|false|off|"") value="no" ;;
    esac
    printf '%s\n' "$value"
}

validate_ssh_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
}

configure_ssh_policy() {
    local selected="${SSH_PORT:-22}"
    local input change_port

    if [[ -t 0 ]]; then
        echo ""
        if [[ -n "${SSH_PORT_CONFIGURED:-}" ]]; then
            read -r -p "SSH port [${selected}]: " input
            if [[ -n "$input" ]]; then
                selected="$input"
            fi
        else
            read -r -p "Change SSH port from default 22? [y/N]: " change_port
            change_port="$(normalize_yes_no "$change_port")"
            if [[ "$change_port" == "yes" ]]; then
                read -r -p "SSH port [${selected}]: " input
                if [[ -n "$input" ]]; then
                    selected="$input"
                fi
            else
                selected="22"
            fi
        fi
    fi

    if ! validate_ssh_port "$selected"; then
        err "Invalid SSH_PORT: ${selected}"
        exit 1
    fi

    SSH_PORT="$selected"
    mkdir -p "$CONF_DIR"
    echo "$SSH_PORT" > "${CONF_DIR}/.ssh_port"
    info "SSH port allowed by firewall: ${SSH_PORT}"
}

split_host_port() {
    local value="$1"
    local __host_var="$2"
    local __port_var="$3"
    local host port

    host="${value%:*}"
    port="${value##*:}"
    printf -v "$__host_var" '%s' "$host"
    printf -v "$__port_var" '%s' "$port"
}

prompt_required() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        read -r -p "$prompt" value
        if [[ -z "$value" ]]; then
            warn "This value is required."
        fi
    done
    printf '%s\n' "$value"
}

write_egress_env() {
    mkdir -p "$CONF_DIR"
    cat > "${CONF_DIR}/egress.env" <<EOF
EGRESS_MODE=${EGRESS_MODE}
EGRESS_SOCKS5_ADDR=${EGRESS_SOCKS5_ADDR}
EGRESS_SOCKS5_USERNAME=${EGRESS_SOCKS5_USERNAME}
EGRESS_SOCKS5_PASSWORD=${EGRESS_SOCKS5_PASSWORD}
EOF
    chmod 600 "${CONF_DIR}/egress.env"
}

configure_egress_policy() {
    # proxy 域名的 TCP 80/443 和 UDP 443 可以从本机 VPS 直接出站，
    # 也可以交给本机 Xray/sing-box 暴露的 SOCKS5 再出站。
    local selected addr input
    selected="$(normalize_egress_mode "${EGRESS_MODE:-direct}")"
    addr="${EGRESS_SOCKS5_ADDR:-127.0.0.1:1080}"

    if [[ -t 0 ]]; then
        echo ""
        echo "Proxy egress mode:"
        echo "  1) direct  - this VPS connects to target sites directly"
        echo "  2) socks5  - send proxy traffic to a local SOCKS5 outbound"
        read -r -p "Select proxy egress mode [direct/socks5, default: ${selected}]: " input
        if [[ -n "$input" ]]; then
            selected="$(normalize_egress_mode "$input")"
        fi

        if [[ "$selected" == "socks5" ]]; then
            read -r -p "SOCKS5 outbound address, ip:port [${addr}]: " input
            if [[ -n "$input" ]]; then
                addr="$input"
            fi
        fi
    fi

    case "$selected" in
        direct|socks5) ;;
        *) err "Invalid EGRESS_MODE: ${selected}. Use direct or socks5."; exit 1 ;;
    esac

    if [[ "$selected" == "socks5" ]] && ! validate_socks5_addr "$addr"; then
        err "Invalid EGRESS_SOCKS5_ADDR: ${addr}. Expected ip:port, for example 127.0.0.1:1080."
        exit 1
    fi

    EGRESS_MODE="$selected"
    EGRESS_SOCKS5_ADDR="$addr"
    write_egress_env

    if [[ "$EGRESS_MODE" == "socks5" ]]; then
        info "Proxy egress mode: socks5 via ${EGRESS_SOCKS5_ADDR}"
        note "Your local SOCKS5 service must be reachable from this VPS and must enable UDP for QUIC."
    else
        info "Proxy egress mode: direct from this VPS"
    fi
    note "Proxy egress policy saved to ${CONF_DIR}/egress.env"
}

configure_xray_policy() {
    local selected input
    selected="$(normalize_yes_no "${XRAY_INSTALL:-no}")"

    if [[ "$EGRESS_MODE" != "socks5" ]]; then
        XRAY_INSTALL="no"
        note "Xray install skipped because proxy egress mode is direct."
        return 0
    fi

    if [[ -t 0 ]]; then
        echo ""
        read -r -p "Install local Xray SOCKS5 -> SS2022 outbound? [y/N]: " input
        if [[ -n "$input" ]]; then
            selected="$(normalize_yes_no "$input")"
        fi
    fi

    case "$selected" in
        yes|no) ;;
        *) err "Invalid XRAY_INSTALL: ${selected}. Use yes or no."; exit 1 ;;
    esac

    XRAY_INSTALL="$selected"
    if [[ "$XRAY_INSTALL" != "yes" ]]; then
        note "Xray install skipped; make sure ${EGRESS_SOCKS5_ADDR} is provided by another SOCKS5 service."
        return 0
    fi

    if [[ -t 0 ]]; then
        [[ -z "$SS2022_ADDRESS" ]] && SS2022_ADDRESS="$(prompt_required "SS2022 server address: ")"
        [[ -z "$SS2022_PORT" ]] && SS2022_PORT="$(prompt_required "SS2022 server port: ")"
        [[ -z "$SS2022_METHOD" ]] && SS2022_METHOD="$(prompt_required "SS2022 method: ")"
        [[ -z "$SS2022_PASSWORD" ]] && SS2022_PASSWORD="$(prompt_required "SS2022 password: ")"
    fi

    [[ -n "$SS2022_ADDRESS" ]] || { err "SS2022_ADDRESS is required when XRAY_INSTALL=yes."; exit 1; }
    [[ "$SS2022_PORT" =~ ^[0-9]+$ ]] || { err "SS2022_PORT must be a number."; exit 1; }
    (( SS2022_PORT >= 1 && SS2022_PORT <= 65535 )) || { err "SS2022_PORT must be between 1 and 65535."; exit 1; }
    [[ -n "$SS2022_METHOD" ]] || { err "SS2022_METHOD is required when XRAY_INSTALL=yes."; exit 1; }
    [[ -n "$SS2022_PASSWORD" ]] || { err "SS2022_PASSWORD is required when XRAY_INSTALL=yes."; exit 1; }

    info "Xray will listen on SOCKS5 ${EGRESS_SOCKS5_ADDR} and forward to SS2022 ${SS2022_ADDRESS}:${SS2022_PORT}"
}

render_xray_config() {
    local inbound_host inbound_port
    split_host_port "$EGRESS_SOCKS5_ADDR" inbound_host inbound_port

    mkdir -p /usr/local/etc/xray
    python3 - "$inbound_host" "$inbound_port" "$SS2022_ADDRESS" "$SS2022_PORT" "$SS2022_METHOD" "$SS2022_PASSWORD" /usr/local/etc/xray/config.json <<'PYEOF'
import json
import sys

inbound_host, inbound_port, ss_addr, ss_port, ss_method, ss_password, output = sys.argv[1:]
config = {
    "inbounds": [
        {
            "protocol": "socks",
            "listen": inbound_host,
            "port": int(inbound_port),
            "tag": "socks5-in",
            "settings": {
                "auth": "noauth",
                "udp": True,
                "ip": inbound_host,
                "userLevel": 0,
            },
        }
    ],
    "log": {
        "loglevel": "warning",
    },
    "outbounds": [
        {
            "protocol": "shadowsocks",
            "settings": {
                "servers": [
                    {
                        "address": ss_addr,
                        "method": ss_method,
                        "password": ss_password,
                        "port": int(ss_port),
                    }
                ],
            },
            "tag": "ss2022-out",
        },
    ],
    "routing": {
        "rules": [
            {
                "inboundTag": ["socks5-in"],
                "outboundTag": "ss2022-out",
                "type": "field",
            }
        ],
    },
}
with open(output, "w", encoding="utf-8") as fh:
    json.dump(config, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF
    # The official Xray service may run as a non-root user, so the config must
    # be readable by that service account while remaining writable only by root.
    chmod 644 /usr/local/etc/xray/config.json
}

xray_installed() {
    command -v xray >/dev/null 2>&1 && return 0
    [[ -x /usr/local/bin/xray ]] && return 0
    systemctl list-unit-files xray.service >/dev/null 2>&1 && return 0
    [[ -f /etc/systemd/system/xray.service || -f /lib/systemd/system/xray.service ]] && return 0
    return 1
}

install_xray_if_requested() {
    [[ "$XRAY_INSTALL" == "yes" ]] || return 0

    if xray_installed; then
        info "Existing Xray installation detected; skipping official installer."
    else
        info "Installing Xray official release..."
        local installer
        installer="$(mktemp /tmp/xray-install.XXXXXX.sh)"
        curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$installer"
        chmod +x "$installer"
        run_quiet "Running Xray official installer..." bash "$installer" install
        rm -f "$installer"
    fi

    render_xray_config
    mkdir -p "$CONF_DIR"
    touch "${CONF_DIR}/.xray_managed"
    systemctl enable xray
    systemctl restart xray || { err "xray failed to start"; journalctl -u xray --no-pager -n 30; exit 1; }
    ok "Xray ready and configured: ${EGRESS_SOCKS5_ADDR} -> ${SS2022_ADDRESS}:${SS2022_PORT}"
}


download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --retry 2 --retry-delay 1 "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=10 --tries=2 -O "$output" "$url"
    else
        err "curl or wget is required for one-line remote install."
        exit 1
    fi
}

bootstrap_remote_project() {
    local missing=0
    local file

    for file in "${REQUIRED_PROJECT_FILES[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${file}" ]]; then
            missing=1
            break
        fi
    done

    [[ "$missing" == "0" ]] && return 0

    info "Detected one-line remote install mode; downloading full ${REPO_OWNER}/${REPO_NAME} project..."
    local workdir archive_file extracted_dir archive_url
    workdir=$(mktemp -d /tmp/5gpn-install.XXXXXX)
    archive_file="${workdir}/${REPO_NAME}.tar.gz"

    local archive_urls=(
        "https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${REPO_BRANCH}"
        "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
    )

    for archive_url in "${archive_urls[@]}"; do
        if download_file "$archive_url" "$archive_file"; then
            if tar -xzf "$archive_file" -C "$workdir" 2>/dev/null; then
                extracted_dir=$(find "$workdir" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)
                if [[ -n "$extracted_dir" && -f "${extracted_dir}/install.sh" ]]; then
                    chmod +x "${extracted_dir}/install.sh"
                    info "Continuing installation from ${extracted_dir}"
                    cd "$extracted_dir"
                    exec bash "${extracted_dir}/install.sh" "$@"
                fi
            fi
        fi
        warn "Unable to download project archive from ${archive_url}; trying next source..."
    done

    warn "Archive download failed; falling back to raw.githubusercontent.com file download."
    extracted_dir="${workdir}/${REPO_NAME}"
    mkdir -p "${extracted_dir}/tests"
    download_file "${REPO_RAW_BASE}/install.sh" "${extracted_dir}/install.sh"
    for file in "${REQUIRED_PROJECT_FILES[@]}"; do
        download_file "${REPO_RAW_BASE}/${file}" "${extracted_dir}/${file}"
    done
    chmod +x "${extracted_dir}/install.sh" "${extracted_dir}/update-rules.sh" "${extracted_dir}/renew-hook.sh"
    info "Continuing installation from ${extracted_dir}"
    cd "$extracted_dir"
    exec bash "${extracted_dir}/install.sh" "$@"
}

# =============================================================================
# Command-line dispatch
# =============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTION]

Options:
  (none)         Full interactive installation
  --status       Show service status
  --update-rules Update GFWList/ChinaList/custom rules and restart mosdns
  --renew-cert   Force renew certificates and reload services
  --uninstall    Remove all installed components
  -h, --help     Show this help

Environment variables (for non-interactive use):
  DOMAIN         Your own domain name that resolves to this VPS
  SKIP_DNS_CHECK Skip public A-record verification when set to 1
  OVERSEAS_DNS   Backward-compatible alias for PRIVATE_OVERSEAS_DNS
  NPN_CLIENT_CIDRS  CIDRs treated as private/NPN DNS clients, default 172.22.0.0/16
  PRIVATE_OVERSEAS_DNS  Overseas upstream DNS for 172.22.0.0/16 DoT clients
  PUBLIC_OVERSEAS_DNS   Overseas upstream DNS for non-private DoT clients
  SNIPROXY_DNS   Resolver upstream DNS for TCP sniproxy backends
  SNIPROXY_REBUILD Rebuild source-installed sniproxy when set to 1
  EGRESS_MODE    Proxy egress mode: direct or socks5
  EGRESS_SOCKS5_ADDR      SOCKS5 outbound address (ip:port) when EGRESS_MODE=socks5
  EGRESS_SOCKS5_USERNAME  Optional SOCKS5 username
  EGRESS_SOCKS5_PASSWORD  Optional SOCKS5 password
  XRAY_INSTALL  Install local Xray SOCKS5 -> SS2022 outbound when set to 1/yes
  SS2022_ADDRESS Required SS2022 server address when XRAY_INSTALL=yes
  SS2022_PORT    Required SS2022 server port when XRAY_INSTALL=yes
  SS2022_METHOD  Required SS2022 method when XRAY_INSTALL=yes
  SS2022_PASSWORD Required SS2022 password when XRAY_INSTALL=yes
  EMAIL          Email for Let's Encrypt
EOF
}

# =============================================================================
# Basic checks
# =============================================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        err "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS" in
        ubuntu|debian)
            PKG_MGR="apt-get"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                PKG_MGR="dnf"
            else
                PKG_MGR="yum"
            fi
            ;;
        *)
            err "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    info "Detected OS: $OS $VER (package manager: $PKG_MGR)"
}

get_public_ip() {
    PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null || \
                curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || \
                curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || echo "")
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' || echo "")
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        err "Failed to detect public IPv4 address. Please set PUBLIC_IP manually."
        exit 1
    fi
    info "Public IP detected: $PUBLIC_IP"
}

check_port_53() {
    info "Checking port 53 availability..."
    local pids pid proc confirm
    pids=$(find_port53_pids)

    if [[ -n "$pids" ]]; then
        pid=$(echo "$pids" | head -n1)
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        warn "Port 53 is already in use by: $proc (PID: $pid)"

        read -r -p "Stop and disable '$proc' to free port 53? [Y/n]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            err "Port 53 must be free for mosdns to start. Aborting."
            exit 1
        fi

        while read -r pid; do
            [[ -z "$pid" ]] && continue
            proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            stop_port53_owner "$pid" "$proc"
        done <<< "$pids"

        if ! wait_for_port53_free; then
            warn "Port 53 is still in use after stopping services. Last listeners:"
            list_port53_listeners >&2 || true
            err "Failed to free port 53. Please manually stop the service using it."
            exit 1
        fi
        ok "Port 53 is now free"
    else
        ok "Port 53 is available"
    fi
}

systemd_unit_for_pid() {
    local pid="${1:-}"
    [[ -z "$pid" || ! -r "/proc/$pid/cgroup" ]] && return 0
    grep -aoE '[^/]+\.service' "/proc/$pid/cgroup" | head -n1 || true
}

find_port53_pids() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lnptu 2>/dev/null | awk '
            $5 ~ /(^|\]|:)53$/ || $5 ~ /:53$/ {
                line=$0
                while (match(line, /pid=[0-9]+/)) {
                    print substr(line, RSTART + 4, RLENGTH - 4)
                    line=substr(line, RSTART + RLENGTH)
                }
            }' | sort -u
        return 0
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN -t 2>/dev/null | sort -u
        return 0
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -lnptu 2>/dev/null | awk '
            $4 ~ /(^|\]|:)53$/ || $4 ~ /:53$/ {
                split($7, p, "/")
                if (p[1] ~ /^[0-9]+$/) {
                    print p[1]
                }
            }' | sort -u
        return 0
    fi

    return 0
}

wait_for_port53_free() {
    local i
    for i in $(seq 1 15); do
        if [[ -z "$(find_port53_pids)" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

list_port53_listeners() {
    if command -v ss >/dev/null 2>&1; then
        ss -lnptu 2>/dev/null | awk 'NR == 1 || $5 ~ /(^|\]|:)53$/ || $5 ~ /:53$/ {print}'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:53 -iUDP:53 -sTCP:LISTEN 2>/dev/null || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnptu 2>/dev/null | awk 'NR <= 2 || $4 ~ /(^|\]|:)53$/ || $4 ~ /:53$/ {print}'
    fi
}

ensure_system_dns() {
    local resolv_conf="/etc/resolv.conf"
    local backup="/etc/resolv.conf.proxy-gateway.bak"

    if [[ -f "$resolv_conf" ]] && grep -Eq '^nameserver[[:space:]]+([0-9a-fA-F:.]+)' "$resolv_conf"; then
        if ! grep -Eq '^nameserver[[:space:]]+(127\.0\.0\.53|127\.0\.0\.1|::1)([[:space:]]|$)' "$resolv_conf"; then
            return 0
        fi
    fi

    warn "Writing fallback DNS to /etc/resolv.conf before changing local DNS services"
    if [[ ! -e "$backup" && -e "$resolv_conf" ]]; then
        cp -aL "$resolv_conf" "$backup" 2>/dev/null || true
    fi
    rm -f "$resolv_conf"
    cat > "$resolv_conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
}

stop_port53_owner() {
    local pid="${1:-}"
    local proc="${2:-unknown}"
    local unit
    unit=$(systemd_unit_for_pid "$pid")

    ensure_system_dns

    if [[ -n "$unit" ]] && command -v systemctl >/dev/null 2>&1; then
        info "Stopping systemd unit owning port 53: $unit"
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    fi

    case "$proc" in
        systemd-resolve|systemd-resolved)
            info "Stopping systemd-resolved service to release DNS stub port 53"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop systemd-resolved.service 2>/dev/null || true
                systemctl disable systemd-resolved.service 2>/dev/null || true
            fi
            ;;
        dnsdist)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop dnsdist.socket dnsdist.service 2>/dev/null || true
                systemctl disable dnsdist.socket dnsdist.service 2>/dev/null || true
                systemctl reset-failed dnsdist.socket dnsdist.service 2>/dev/null || true
            fi
            ;;
        dnsmasq)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop dnsmasq.service 2>/dev/null || true
                systemctl disable dnsmasq.service 2>/dev/null || true
            fi
            ;;
        named)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl stop named.service bind9.service 2>/dev/null || true
                systemctl disable named.service bind9.service 2>/dev/null || true
            fi
            ;;
    esac

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# Dependencies
# =============================================================================
ensure_pip3_available() {
    if command -v pip3 >/dev/null 2>&1; then
        return 0
    fi

    warn "pip3 is only needed for the certbot compatibility fallback; installing it now..."
    local pip_pkg_mgr="${PKG_MGR:-}"
    if [[ -z "$pip_pkg_mgr" ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            pip_pkg_mgr="apt-get"
        elif command -v dnf >/dev/null 2>&1; then
            pip_pkg_mgr="dnf"
        elif command -v yum >/dev/null 2>&1; then
            pip_pkg_mgr="yum"
        fi
    fi

    case "$pip_pkg_mgr" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            run_quiet "Installing python3-pip fallback package..." apt-get install -y -qq python3-pip
            ;;
        dnf|yum)
            run_quiet "Installing python3-pip fallback package..." "$pip_pkg_mgr" install -y -q python3-pip
            ;;
        *)
            err "Could not determine package manager for python3-pip fallback."
            return 1
            ;;
    esac
}

install_deps() {
    info "Installing system dependencies..."

    case "$PKG_MGR" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            run_quiet "Updating apt package index..." apt-get update -qq
            run_quiet "Installing apt packages for 5GPN runtime and source builds..." apt-get install -y -qq \
                build-essential git wget curl unzip ca-certificates \
                iproute2 procps lsof net-tools \
                libev-dev libssl-dev \
                autoconf automake libtool pkg-config \
                certbot dnsdist \
                python3 jq libcap2-bin \
                nftables
            apt-get install -y -qq libpcre3-dev >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || \
                apt-get install -y -qq libpcre2-dev >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
            apt-get install -y -qq libudns-dev >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
            ;;
        dnf|yum)
            run_quiet "Installing RPM packages for 5GPN runtime and source builds..." "$PKG_MGR" install -y -q \
                gcc gcc-c++ make git wget curl unzip ca-certificates \
                iproute procps-ng lsof net-tools \
                libev-devel pcre-devel openssl-devel \
                autoconf automake libtool pkgconfig \
                certbot dnsdist \
                python3 jq libcap-ng-utils \
                nftables
            "$PKG_MGR" install -y -q udns-devel >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
            ;;
    esac

    # Ensure Go is installed (for quic-proxy compilation)
    if ! command -v go >/dev/null 2>&1; then
        info "Installing Go compiler..."
        GO_VER="1.22.4"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GO_ARCH="amd64" ;;
            aarch64|arm64) GO_ARCH="arm64" ;;
            *) GO_ARCH="amd64" ;;
        esac
        wget -q "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz" -O /tmp/go.tar.gz
        rm -rf /usr/local/go
        tar -C /usr/local -xzf /tmp/go.tar.gz
        rm -f /tmp/go.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    fi

    ok "Go version: $(go version)"

    # Fix certbot compatibility on newer Python versions (e.g. 3.12+)
    if command -v certbot >/dev/null 2>&1; then
        if ! certbot --version >/dev/null 2>&1; then
            warn "Certbot has compatibility issues with the current Python version. Attempting to fix..."
            ensure_pip3_available
            pip3 install --upgrade --break-system-packages certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || \
                pip3 install --upgrade certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
        fi
    fi

    # Verify critical binaries
    for bin in certbot dnsdist; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            err "Required package '$bin' was not installed successfully."
            err "Please check your package manager output above."
            exit 1
        fi
    done
}

# =============================================================================
# Domain configuration
# =============================================================================
generate_domain() {
    # Operators should bring their own domain. This avoids provider-specific
    # automation and makes the gateway fit enterprise DNS / 5G private network
    # environments where zones are often managed outside the VPS.
    if [[ -n "${DOMAIN:-}" ]]; then
        DOMAIN="${DOMAIN%.}"
        if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
            err "Invalid DOMAIN: $DOMAIN"
            err "Please provide a full domain like dot.example.com."
            exit 1
        fi
        info "Using configured domain: $DOMAIN"
        note "Make sure ${DOMAIN} has an A record pointing to ${PUBLIC_IP} before certificate issuance."
        DOMAIN_PRECONFIGURED=1
        mkdir -p "$CONF_DIR"
        echo "$DOMAIN" > "${CONF_DIR}/.domain"
        return
    fi

    if [[ ! -t 0 ]]; then
        err "DOMAIN is required in non-interactive mode."
        err "Please point your own domain's A record to ${PUBLIC_IP}, then rerun:"
        err "  DOMAIN=dot.example.com $0"
        exit 1
    fi

    echo ""
    echo "=================================================="
    echo "  Configure your DoT domain"
    echo "=================================================="
    echo "  Please create an A record pointing to: ${PUBLIC_IP}"
    echo "  Example: dot.example.com -> ${PUBLIC_IP}"
    echo "=================================================="
    echo ""
    while [[ -z "${DOMAIN:-}" ]]; do
        read -r -p "Domain name for this VPS: " DOMAIN
        DOMAIN="${DOMAIN%.}"
        if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
            warn "Invalid domain name, please enter a full domain like dot.example.com."
            DOMAIN=""
        fi
    done

    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"
}

verify_domain_resolution() {
    # Let's Encrypt HTTP-01 validation depends on public DNS. We warn instead
    # of aborting so operators can continue in split-horizon or staged DNS
    # environments, then let certbot provide the final authority.
    mkdir -p "$CONF_DIR"
    echo "$DOMAIN" > "${CONF_DIR}/.domain"

    if [[ "${SKIP_DNS_CHECK:-0}" == "1" ]]; then
        warn "Skipping public DNS A-record verification for ${DOMAIN}."
        return 0
    fi

    info "Verifying DNS A record: ${DOMAIN} -> ${PUBLIC_IP}"
    info "Checking local resolver plus public resolvers: 1.1.1.1, 8.8.8.8, 223.5.5.5, 119.29.29.29"
    local waited=0 resolver resolved answers=""
    while [[ $waited -lt 120 ]]; do
        answers=""

        resolved=$(dig +time=2 +tries=1 +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ' || true)
        if grep -qw "$PUBLIC_IP" <<<"$resolved"; then
            ok "DNS verification passed via local resolver: $DOMAIN -> $PUBLIC_IP"
            return 0
        fi
        [[ -n "$resolved" ]] && answers+="local=${resolved}; "

        for resolver in 1.1.1.1 8.8.8.8 223.5.5.5 119.29.29.29; do
            resolved=$(dig +time=2 +tries=1 +short A "$DOMAIN" @"$resolver" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ' || true)
            if grep -qw "$PUBLIC_IP" <<<"$resolved"; then
                ok "DNS verification passed via ${resolver}: $DOMAIN -> $PUBLIC_IP"
                return 0
            fi
            [[ -n "$resolved" ]] && answers+="${resolver}=${resolved}; "
        done

        printf '\r[INFO] Waiting for DNS propagation... %3ss/120s (%s)' "$waited" "${answers:-no A answer yet}"
        sleep 5
        waited=$((waited + 5))
    done
    echo ""
    warn "DNS A record did not resolve to ${PUBLIC_IP} within 120 seconds."
    warn "Last observed answers: ${answers:-none}"
    warn "Continuing installation; Let's Encrypt may fail until your DNS is correct."
}


copy_mosdns_cert() {
    local cert_domain="${1:-$DOMAIN}"
    local cert_live_dir="/etc/letsencrypt/live/${cert_domain}"

    if [[ ! -f "${cert_live_dir}/fullchain.pem" || ! -f "${cert_live_dir}/privkey.pem" ]]; then
        return 1
    fi

    info "Copying certificates to /etc/mosdns/certs/ and /etc/dnsdist/certs/ ..."
    mkdir -p /etc/mosdns/certs /etc/dnsdist/certs
    cp "${cert_live_dir}/fullchain.pem" /etc/mosdns/certs/fullchain.pem
    cp "${cert_live_dir}/privkey.pem" /etc/mosdns/certs/privkey.pem
    cp "${cert_live_dir}/fullchain.pem" /etc/dnsdist/certs/fullchain.pem
    cp "${cert_live_dir}/privkey.pem" /etc/dnsdist/certs/privkey.pem
    chmod 644 /etc/mosdns/certs/fullchain.pem
    chmod 600 /etc/mosdns/certs/privkey.pem
    chmod 644 /etc/dnsdist/certs/fullchain.pem
    chmod 640 /etc/dnsdist/certs/privkey.pem
    if id _dnsdist >/dev/null 2>&1; then
        chown -R _dnsdist:_dnsdist /etc/dnsdist/certs
    elif id dnsdist >/dev/null 2>&1; then
        chown -R dnsdist:dnsdist /etc/dnsdist/certs
    fi
    ok "Certificates copied to mosdns and dnsdist cert directories"
}

# =============================================================================
# Let's Encrypt Certificate
# =============================================================================
install_cert() {
    local certbot_cmd
    install_certbot_firewall_hooks

    if copy_mosdns_cert "$DOMAIN"; then
        info "Existing Let's Encrypt certificate found for $DOMAIN; reusing it for installation."
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cp "${SCRIPT_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
        ok "Certificate is ready; renewal deploy hook installed"
        return 0
    fi

    # Normal issuance (first time) - no force-renewal to avoid rate limits
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)

    info "Requesting Let's Encrypt certificate for $DOMAIN..."

    run_certbot() {
        open_cert_http_port
        trap restore_reverse_proxy_firewall RETURN
        if "${certbot_cmd[@]}"; then
            return 0
        fi
        # Check for known Python compatibility error
        if "${certbot_cmd[@]}" 2>&1 | grep -q "AttributeError" || \
           certbot --version 2>&1 | grep -q "AttributeError"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            ensure_pip3_available
            pip3 install --upgrade --break-system-packages certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || \
                pip3 install --upgrade certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
            info "Retrying certificate request..."
            "${certbot_cmd[@]}"
        else
            return 1
        fi
    }

    if ! run_certbot; then
        err "Certificate request failed. Please check:"
        err "  1. Domain $DOMAIN resolves to this VPS ($PUBLIC_IP)"
        err "  2. TCP/80 is not occupied by another service"
        err "  3. Firewall allows temporary TCP/80 access for HTTP-01"
        err "  4. Let's Encrypt ACME service is currently available"
        err "  5. Let's Encrypt rate limits have not been hit"
        exit 1
    fi

    if ! copy_mosdns_cert "$DOMAIN"; then
        warn "Could not find issued certificate live directory for $DOMAIN"
    fi

    # Deploy renewal hook (also handles cert copy on renewal)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cp "${SCRIPT_DIR}/renew-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    ok "Certificate is ready; renewal deploy hook installed"
}

# =============================================================================
# sniproxy (TCP)
# =============================================================================
install_sniproxy() {
    # Always use the upstream source build. Distro packages can land in
    # /usr/sbin/sniproxy and may be built with different resolver support,
    # which has caused service start failures with this gateway configuration.
    local sniproxy_bin="/usr/local/sbin/sniproxy"

    if [[ ! -x "$sniproxy_bin" || "${SNIPROXY_REBUILD:-0}" == "1" ]]; then
        info "Compiling sniproxy from source (distro packages may use incompatible builds)..."
        note "Target binary: ${sniproxy_bin}"
        note "Set SNIPROXY_REBUILD=1 to force a clean rebuild on future runs."
        mkdir -p "$SRC_DIR"
        cd "$SRC_DIR"

        if [[ ! -d sniproxy ]]; then
            if ! command -v git >/dev/null 2>&1; then
                err "git is required to build sniproxy from source."
                exit 1
            fi
            info "Cloning upstream sniproxy source..."
            git clone --depth=1 https://github.com/dlundquist/sniproxy.git
        elif [[ -d sniproxy/.git ]]; then
            info "Refreshing existing sniproxy source tree..."
            git -C sniproxy pull --ff-only || warn "Unable to update existing sniproxy source tree; using local copy."
        fi
        cd sniproxy

        info "Preparing sniproxy build system..."
        DEBEMAIL="root@localhost" DEBFULLNAME="root" ./autogen.sh
        info "Configuring sniproxy with DNS resolver support..."
        ./configure --prefix=/usr/local --sysconfdir=/etc --enable-dns
        make clean >/dev/null 2>&1 || true
        info "Building sniproxy with $(nproc) parallel jobs..."
        make -j"$(nproc)"
        info "Installing sniproxy to /usr/local..."
        make install
    else
        info "Using existing source-built sniproxy: $sniproxy_bin"
    fi

    if [[ ! -x "$sniproxy_bin" ]]; then
        err "Source-built sniproxy binary not found at $sniproxy_bin"
        exit 1
    fi
    ok "sniproxy binary ready: $sniproxy_bin"

    if [[ -f "${SCRIPT_DIR}/sniproxy.conf" ]]; then
        local sniproxy_nameservers
        sniproxy_nameservers=$(render_sniproxy_dns_nameservers "$SNIPROXY_DNS")
        info "Rendering /etc/sniproxy.conf with dedicated IPv4-only resolver settings..."
        python3 - "${SCRIPT_DIR}/sniproxy.conf" "$sniproxy_nameservers" /etc/sniproxy.conf <<'PYEOF'
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__SNIPROXY_NAMESERVERS__", sys.argv[2])
with open(sys.argv[3], "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
    else
        err "sniproxy.conf not found in ${SCRIPT_DIR}"
        exit 1
    fi

    # systemd service
    cat > /etc/systemd/system/sniproxy.service <<'EOF'
[Unit]
Description=sniproxy (TCP SNI transparent proxy)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy.conf -f
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sniproxy
    ok "sniproxy installed"
}

# =============================================================================
# 5gpn-tcp-proxy (TCP Host/SNI proxy with SOCKS5 egress)
# =============================================================================
install_5gpn_tcp_proxy() {
    case "$EGRESS_MODE" in
        direct|socks5) ;;
        *) err "Invalid EGRESS_MODE: ${EGRESS_MODE}. Use direct or socks5."; exit 1 ;;
    esac

    info "Compiling 5gpn-tcp-proxy (TCP Host/SNI proxy with optional SOCKS5 egress)..."
    mkdir -p "${BASE_DIR}/bin" "${SRC_DIR}" "${CONF_DIR}"
    cp "${SCRIPT_DIR}/5gpn-tcp-proxy.go" "${SRC_DIR}/5gpn-tcp-proxy.go"
    cd "${SRC_DIR}"

    export PATH=$PATH:/usr/local/go/bin
    go build -ldflags="-s -w" -o "${BASE_DIR}/bin/5gpn-tcp-proxy" 5gpn-tcp-proxy.go

    write_egress_env

    cat > /etc/systemd/system/5gpn-tcp-proxy.service <<'EOF'
[Unit]
Description=5GPN TCP Host/SNI proxy
After=network.target

[Service]
Type=simple
Environment="EGRESS_MODE=direct"
Environment="EGRESS_SOCKS5_ADDR=127.0.0.1:1080"
Environment="EGRESS_SOCKS5_USERNAME="
Environment="EGRESS_SOCKS5_PASSWORD="
EnvironmentFile=-/opt/proxy-gateway/etc/egress.env
ExecStart=/opt/proxy-gateway/bin/5gpn-tcp-proxy -http=0.0.0.0:80 -https=0.0.0.0:443 -egress=${EGRESS_MODE} -socks5=${EGRESS_SOCKS5_ADDR} -socks5-user=${EGRESS_SOCKS5_USERNAME} -socks5-pass=${EGRESS_SOCKS5_PASSWORD}
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [[ "$EGRESS_MODE" == "socks5" ]]; then
        systemctl enable 5gpn-tcp-proxy
        systemctl disable sniproxy 2>/dev/null || true
        note "TCP egress mode: socks5 via ${EGRESS_SOCKS5_ADDR}; 5gpn-tcp-proxy will bind TCP 80/443."
    else
        systemctl disable 5gpn-tcp-proxy 2>/dev/null || true
        note "TCP egress mode: direct; sniproxy will bind TCP 80/443."
    fi
    ok "5gpn-tcp-proxy installed"
}

# =============================================================================
# quic-proxy (UDP / QUIC SNI proxy)
# =============================================================================
install_quic_proxy() {
    info "Compiling quic-proxy (UDP/QUIC SNI proxy)..."
    mkdir -p "${BASE_DIR}/bin"
    mkdir -p "${SRC_DIR}"
    cp "${SCRIPT_DIR}/quic-proxy.go" "${SRC_DIR}/quic-proxy.go"
    cd "${SRC_DIR}"

    export PATH=$PATH:/usr/local/go/bin
    go build -ldflags="-s -w" -o "${BASE_DIR}/bin/quic-proxy" quic-proxy.go

    # systemd service
    cat > /etc/systemd/system/quic-proxy.service <<'EOF'
[Unit]
Description=quic-proxy (UDP/QUIC SNI transparent proxy)
After=network.target

[Service]
Type=simple
Environment="EGRESS_MODE=direct"
Environment="EGRESS_SOCKS5_ADDR=127.0.0.1:1080"
Environment="EGRESS_SOCKS5_USERNAME="
Environment="EGRESS_SOCKS5_PASSWORD="
EnvironmentFile=-/opt/proxy-gateway/etc/egress.env
ExecStart=/opt/proxy-gateway/bin/quic-proxy -l 0.0.0.0:443 -egress=${EGRESS_MODE} -socks5=${EGRESS_SOCKS5_ADDR} -socks5-user=${EGRESS_SOCKS5_USERNAME} -socks5-pass=${EGRESS_SOCKS5_PASSWORD}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable quic-proxy
    ok "quic-proxy installed"
}

# =============================================================================
# China DNS race proxy (UDP DNS upstream racing for ChinaList)
# =============================================================================
install_china_dns_race_proxy() {
    info "Compiling china-dns-race-proxy..."
    mkdir -p "${BASE_DIR}/bin"
    mkdir -p "${SRC_DIR}"
    cp "${SCRIPT_DIR}/china-dns-race-proxy.go" "${SRC_DIR}/china-dns-race-proxy.go"
    cd "${SRC_DIR}"

    export PATH=$PATH:/usr/local/go/bin
    go build -ldflags="-s -w" -o "${BASE_DIR}/bin/china-dns-race-proxy" china-dns-race-proxy.go

    cat > /etc/systemd/system/china-dns-race-proxy.service <<'EOF'
[Unit]
Description=China DNS race proxy
After=network.target
Before=mosdns.service

[Service]
Type=simple
Environment="CHINA_DNS_ECS=139.226.48.0/24"
Environment="CHINA_DNS_UPSTREAMS=223.5.5.5:53,223.6.6.6:53"
EnvironmentFile=-/opt/proxy-gateway/etc/china-dns-race-proxy.env
ExecStart=/opt/proxy-gateway/bin/china-dns-race-proxy -l 127.0.0.1:5301 -upstreams ${CHINA_DNS_UPSTREAMS} -ecs ${CHINA_DNS_ECS}
Restart=on-failure
RestartSec=3
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable china-dns-race-proxy
    ok "china-dns-race-proxy installed"
}

# =============================================================================
# mosdns (DoT + Smart DNS)
# =============================================================================
install_mosdns_binary() {
    local mosdns_bin="/usr/local/bin/mosdns"
    if [[ -x "$mosdns_bin" ]]; then
        info "mosdns already installed: $($mosdns_bin version 2>/dev/null | head -n1 || echo "$mosdns_bin")"
        return
    fi

    local arch url tmp
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) err "Unsupported CPU architecture for mosdns: $(uname -m)"; exit 1 ;;
    esac

    if [[ "$MOSDNS_VERSION" == "latest" ]]; then
        url="https://github.com/IrineSistiana/mosdns/releases/latest/download/mosdns-linux-${arch}.zip"
    else
        url="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${arch}.zip"
    fi

    info "Downloading mosdns (${MOSDNS_VERSION}, linux-${arch})..."
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "${tmp}/mosdns.zip"
    unzip -oq "${tmp}/mosdns.zip" -d "$tmp"
    install -m755 "${tmp}/mosdns" "$mosdns_bin"
    rm -rf "$tmp"
    ok "mosdns installed: $($mosdns_bin version 2>/dev/null | head -n1 || echo "$mosdns_bin")"
}

install_mosdns() {
    info "Configuring mosdns..."
    install_mosdns_binary

    mkdir -p /etc/mosdns/rules/custom /etc/mosdns/subscriptions /etc/mosdns/certs
    cp "${SCRIPT_DIR}/mosdns_config.yaml" /etc/mosdns/config.yaml.template
    cp "${SCRIPT_DIR}/update-rules.sh" /usr/local/bin/update-mosdns-rules.sh
    chmod +x /usr/local/bin/update-mosdns-rules.sh

    echo "$DOMAIN" > /etc/mosdns/.domain
    echo "$PUBLIC_IP" > /etc/mosdns/.public_ip
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/mosdns/.overseas_dns
    echo "$PRIVATE_OVERSEAS_DNS" > /etc/mosdns/.overseas_private_dns
    echo "$PUBLIC_OVERSEAS_DNS" > /etc/mosdns/.overseas_public_dns
    echo "$SNIPROXY_DNS" > /etc/mosdns/.sniproxy_dns
    echo "$NPN_CLIENT_CIDRS" > /etc/mosdns/.npn_client_cidrs
    echo "${DNS_QUERY_LOG:-0}" > /etc/mosdns/.query_log

    local npn_client_cidrs private_upstreams public_upstreams private_query_log_rule public_query_log_rule
    npn_client_cidrs=$(render_mosdns_client_cidrs "$NPN_CLIENT_CIDRS")
    private_upstreams=$(render_mosdns_upstreams "$PRIVATE_OVERSEAS_DNS")
    public_upstreams=$(render_mosdns_upstreams "$PUBLIC_OVERSEAS_DNS")
    private_query_log_rule=$(render_mosdns_query_log_rule "5gpn-private")
    public_query_log_rule=$(render_mosdns_query_log_rule "5gpn-public")

    python3 - /etc/mosdns/config.yaml.template "$PUBLIC_IP" "$npn_client_cidrs" "$private_upstreams" "$public_upstreams" "$private_query_log_rule" "$public_query_log_rule" /etc/mosdns/config.yaml <<'PYEOF'
import sys
template_path, server_ip, npn_client_cidrs, private_upstreams, public_upstreams, private_query_log_rule, public_query_log_rule, output_path = sys.argv[1:9]
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("\ninclude: []\n", "\n")
content = content.replace("__SERVER_IP__", server_ip)
content = content.replace("__NPN_CLIENT_CIDRS__", npn_client_cidrs.rstrip() or '        - "172.22.0.0/16"\n        - "127.0.0.1/32"')
content = content.replace("__PRIVATE_OVERSEAS_UPSTREAMS__", private_upstreams.rstrip() or '        - addr: "udp://1.1.1.1:53"')
content = content.replace("__PUBLIC_OVERSEAS_UPSTREAMS__", public_upstreams.rstrip() or '        - addr: "udp://1.1.1.1:53"')
content = content.replace("__PRIVATE_QUERY_LOG_RULE__", private_query_log_rule.rstrip())
content = content.replace("__PUBLIC_QUERY_LOG_RULE__", public_query_log_rule.rstrip())
with open(output_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

    for file in proxy-domains.txt direct-domains.txt china-domains.txt reject-domains.txt hosts.txt gfwlist.txt chinalist.txt; do
        touch "/etc/mosdns/rules/${file}"
    done
    for category in proxy direct china reject; do
        touch "/etc/mosdns/rules/custom/${category}.txt" "/etc/mosdns/subscriptions/${category}-urls.txt"
    done
    cat > /etc/systemd/system/mosdns.service <<'EOF'
[Unit]
Description=mosdns (5GPN Smart DNS + DoT)
After=network-online.target china-dns-race-proxy.service
Wants=network-online.target china-dns-race-proxy.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mosdns start -d /etc/mosdns -c /etc/mosdns/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mosdns
    ok "mosdns configured"
}

install_dnsdist_frontend() {
    info "Configuring dnsdist DoT frontend..."
    if ! command -v dnsdist >/dev/null 2>&1; then
        err "dnsdist binary not found. Please install dnsdist or rerun dependency installation."
        exit 1
    fi
    if [[ ! -f "${SCRIPT_DIR}/dnsdist.conf.template" ]]; then
        err "dnsdist.conf.template not found in ${SCRIPT_DIR}"
        exit 1
    fi

    mkdir -p /etc/dnsdist/certs
    cp "${SCRIPT_DIR}/dnsdist.conf.template" /etc/dnsdist/dnsdist.conf.template

    local npn_client_cidrs_lua
    npn_client_cidrs_lua="$(render_dnsdist_client_cidrs "$NPN_CLIENT_CIDRS")"
    python3 - /etc/dnsdist/dnsdist.conf.template "$npn_client_cidrs_lua" /etc/dnsdist/dnsdist.conf <<'PYEOF'
import sys
template_path, npn_client_cidrs_lua, output_path = sys.argv[1:4]
with open(template_path, "r", encoding="utf-8") as f:
    content = f.read()
content = content.replace("__NPN_CLIENT_CIDRS_LUA__", npn_client_cidrs_lua)
with open(output_path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF

    if ! dnsdist --check-config -C /etc/dnsdist/dnsdist.conf >/dev/null 2>&1; then
        err "Generated dnsdist configuration failed validation"
        dnsdist --check-config -C /etc/dnsdist/dnsdist.conf || true
        exit 1
    fi

    local dnsdist_bin
    dnsdist_bin="$(command -v dnsdist)"
    mkdir -p /etc/systemd/system/dnsdist.service.d
    cat > /etc/systemd/system/dnsdist.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=${dnsdist_bin} --supervised -C /etc/dnsdist/dnsdist.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
EOF
    systemctl disable dnsdist.socket 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable dnsdist
    ok "dnsdist DoT frontend configured"
}

# =============================================================================
# Rules initialization
# =============================================================================
init_rules() {
    info "Initializing GFWList and ChinaList..."
    /usr/local/bin/update-mosdns-rules.sh || warn "Rule update failed, will retry later"
}

# =============================================================================
# System tuning
# =============================================================================
system_tuning() {
    info "Applying kernel and system tuning..."

    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d
    echo nf_conntrack > /etc/modules-load.d/proxy-gateway-net.conf

    cat > /etc/sysctl.d/99-proxy-gateway.conf <<'EOF'
# Proxy Gateway Optimizations
fs.file-max=10240000
fs.nr_open=2097152
net.core.default_qdisc=fq
net.core.netdev_max_backlog=65536
net.core.somaxconn=10240000
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.ip_default_ttl=128
net.ipv4.ip_forward=1
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_dsack=1
net.ipv4.tcp_ecn=1
net.ipv4.tcp_fastopen=1027
net.ipv4.tcp_fastopen_blackhole_timeout_sec=0
net.ipv4.tcp_fin_timeout=2
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_max_orphans=10240
net.ipv4.tcp_max_syn_backlog=65536
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_retries1=2
net.ipv4.tcp_retries2=2
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_rmem=8192 65536 134217728
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_wmem=8192 131072 134217728
net.netfilter.nf_conntrack_generic_timeout=10
net.netfilter.nf_conntrack_icmp_timeout=2
net.netfilter.nf_conntrack_max=10240000
net.netfilter.nf_conntrack_tcp_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_close=2
net.netfilter.nf_conntrack_tcp_timeout_close_wait=2
net.netfilter.nf_conntrack_tcp_timeout_established=30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=2
net.netfilter.nf_conntrack_tcp_timeout_last_ack=2
net.netfilter.nf_conntrack_tcp_timeout_max_retrans=2
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=2
net.netfilter.nf_conntrack_tcp_timeout_syn_sent=2
net.netfilter.nf_conntrack_tcp_timeout_time_wait=2
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged=2
net.netfilter.nf_conntrack_udp_timeout=2
net.netfilter.nf_conntrack_udp_timeout_stream=30
vm.swappiness=0
EOF

    local mem_pages
    mem_pages=$(awk '/MemTotal/ { printf "%d", ($2 * 1024) / 4096 }' /proc/meminfo 2>/dev/null || echo "")
    if [[ -n "$mem_pages" && "$mem_pages" -gt 0 ]]; then
        {
            echo "net.ipv4.tcp_mem=$((mem_pages / 100 * 12)) $((mem_pages / 100 * 50)) $((mem_pages / 100 * 70))"
        } >> /etc/sysctl.d/99-proxy-gateway.conf
    fi

    sysctl --system >/dev/null

    # PAM limits (avoid duplicate entries)
    if ! grep -q "proxy-gateway-limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<'EOF'
# proxy-gateway-limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
    fi

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/disable-transparent-huge-pages.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'test -w /sys/kernel/mm/transparent_hugepage/defrag && echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'

[Install]
WantedBy=basic.target
EOF

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-proxy-gateway.conf <<'EOF'
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOF

    systemctl daemon-reload
    systemctl enable --now disable-transparent-huge-pages.service 2>/dev/null || true
    systemctl restart systemd-journald 2>/dev/null || true

    ok "System tuning applied"
}

# =============================================================================
# SSH access
# =============================================================================
configure_ssh_port() {
    info "Configuring SSH daemon port: ${SSH_PORT}"

    if ! validate_ssh_port "$SSH_PORT"; then
        err "Invalid SSH_PORT: ${SSH_PORT}"
        exit 1
    fi

    if [[ ! -d /etc/ssh ]]; then
        warn "/etc/ssh not found; skipping SSH port configuration."
        return 0
    fi

    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cat > /etc/ssh/sshd_config.d/99-5gpn-port.conf <<EOF
Port ${SSH_PORT}
EOF
    elif [[ -f /etc/ssh/sshd_config ]]; then
        cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.5gpn-bak 2>/dev/null || true
        if grep -qE '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
            sed -i -E "s|^[#[:space:]]*Port[[:space:]]+.*|Port ${SSH_PORT}|" /etc/ssh/sshd_config
        else
            printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
        fi
    else
        warn "sshd_config not found; skipping SSH port configuration."
        return 0
    fi

    if command -v sshd >/dev/null 2>&1; then
        sshd -t || { err "sshd configuration validation failed"; exit 1; }
    fi

    if systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        systemctl restart sshd
    elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        systemctl restart ssh
    else
        warn "SSH systemd service not found; configuration written but service was not restarted."
    fi

    ok "SSH configured on port ${SSH_PORT}"
}

# =============================================================================
# Firewall (nftables)
# =============================================================================
setup_firewall() {
    info "Configuring nftables firewall..."

    if ! command -v nft >/dev/null 2>&1; then
        err "nftables is required for firewall management."
        err "Install nftables or rerun install_deps, then run this installer again."
        exit 1
    fi

    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table ip nat {
        chain prerouting {
                type nat hook prerouting priority dstnat; policy accept;
        }
        chain postrouting {
                type nat hook postrouting priority srcnat; policy accept;
        }
}

table ip filter {
        chain input {
                type filter hook input priority filter; policy drop;
                iif "lo" accept
                ct state established,related accept
                icmp type echo-request accept
                icmp type echo-reply accept
                tcp dport ${SSH_PORT} accept
                ip saddr 172.22.0.0/16 tcp dport 53 accept
                ip saddr 172.22.0.0/16 udp dport 53 accept
                tcp dport 853 accept
                ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept
                ip saddr 172.22.0.0/16 udp dport 443 accept
        }
        chain forward {
                type filter hook forward priority filter; policy accept;
        }
        chain output {
                type filter hook output priority filter; policy accept;
        }
}
EOF
    chmod +x /etc/nftables.conf
    nft -f /etc/nftables.conf
    systemctl enable nftables 2>/dev/null || true

    ok "Firewall configured (reverse proxy whitelist: 172.22.0.0/16)"
}

open_cert_http_port() {
    info "Temporarily opening TCP/80 for Let's Encrypt HTTP-01..."

    if command -v nft >/dev/null 2>&1 && nft list table ip filter >/dev/null 2>&1; then
        nft insert rule ip filter input tcp dport 80 accept comment \"proxy-gateway-cert-http\" 2>/dev/null || true
    fi
}

restore_reverse_proxy_firewall() {
    info "Restoring reverse proxy firewall whitelist..."
    setup_firewall >/dev/null 2>&1 || true
}

install_certbot_firewall_hooks() {
    mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post

    cat > /usr/local/bin/proxy-gateway-open-cert-http.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && nft list table ip filter >/dev/null 2>&1; then
    nft insert rule ip filter input tcp dport 80 accept comment "proxy-gateway-cert-http" 2>/dev/null || true
fi
EOF
    cat > /usr/local/bin/proxy-gateway-restore-firewall.sh <<'EOF'
#!/bin/bash
set -e
if command -v nft >/dev/null 2>&1 && [[ -f /etc/nftables.conf ]]; then
    nft -f /etc/nftables.conf 2>/dev/null || true
fi
EOF
    chmod +x /usr/local/bin/proxy-gateway-open-cert-http.sh /usr/local/bin/proxy-gateway-restore-firewall.sh
    cp /usr/local/bin/proxy-gateway-open-cert-http.sh /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh
    cp /usr/local/bin/proxy-gateway-restore-firewall.sh /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
    chmod +x /etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh \
        /etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh
}

# =============================================================================
# Start services
# =============================================================================
start_services() {
    info "Starting services..."
    systemctl restart china-dns-race-proxy || { err "china-dns-race-proxy failed to start"; journalctl -u china-dns-race-proxy --no-pager -n 20; exit 1; }
    systemctl restart mosdns || { err "mosdns failed to start"; journalctl -u mosdns --no-pager -n 30; exit 1; }
    systemctl restart dnsdist || { err "dnsdist failed to start"; journalctl -u dnsdist --no-pager -n 30; exit 1; }
    if [[ -f "${CONF_DIR}/.xray_managed" ]]; then
        systemctl restart xray || { err "xray failed to start"; journalctl -u xray --no-pager -n 30; exit 1; }
    fi
    if [[ "$EGRESS_MODE" == "socks5" ]]; then
        systemctl stop sniproxy 2>/dev/null || true
        systemctl restart 5gpn-tcp-proxy || { err "5gpn-tcp-proxy failed to start"; journalctl -u 5gpn-tcp-proxy --no-pager -n 20; exit 1; }
    else
        systemctl stop 5gpn-tcp-proxy 2>/dev/null || true
        systemctl restart sniproxy || { err "sniproxy failed to start"; journalctl -u sniproxy --no-pager -n 20; exit 1; }
    fi
    systemctl restart quic-proxy || { err "quic-proxy failed to start"; journalctl -u quic-proxy --no-pager -n 20; exit 1; }
    ok "All services started"
}

# =============================================================================
# Cron / Systemd timers
# =============================================================================
setup_schedules() {
    info "Setting up automatic updates..."

    # Weekly rule update (Sunday 03:00)
    cat > /etc/systemd/system/update-mosdns-rules.timer <<'EOF'
[Unit]
Description=Weekly mosdns rules update

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/update-mosdns-rules.service <<'EOF'
[Unit]
Description=Update mosdns GFWList/ChinaList/custom rules

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-mosdns-rules.sh
EOF

    systemctl daemon-reload
    systemctl enable --now update-mosdns-rules.timer

    install_certbot_firewall_hooks

    # Ensure certbot timer is enabled
    systemctl enable --now certbot.timer 2>/dev/null || true

    ok "Schedules configured (rules: weekly, cert: auto)"
}

# =============================================================================
# Status / Uninstall / Helpers
# =============================================================================
show_status() {
    echo "=========================================="
    echo "      Proxy Gateway Status"
    echo "=========================================="
    for svc in dnsdist mosdns sniproxy 5gpn-tcp-proxy quic-proxy china-dns-race-proxy xray; do
        status="$(systemctl is-active "$svc" 2>/dev/null || true)"
        [[ -n "$status" ]] || status="unknown"
        if [[ "$status" == "active" ]]; then
            echo -e "$svc: ${GREEN}running${NC}"
        else
            echo -e "$svc: ${RED}$status${NC}"
        fi
    done
    echo ""
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        echo "Domain: $(cat "${CONF_DIR}/.domain")"
    fi
    echo "Public IP: ${PUBLIC_IP:-N/A}"
    if [[ -f "${CONF_DIR}/egress.env" ]]; then
        echo "TCP egress: $(grep -E '^EGRESS_MODE=' "${CONF_DIR}/egress.env" | cut -d= -f2-) ($(grep -E '^EGRESS_SOCKS5_ADDR=' "${CONF_DIR}/egress.env" | cut -d= -f2-))"
    fi
    echo "=========================================="
}

do_uninstall() {
    warn "This will remove dnsdist, sniproxy, 5gpn-tcp-proxy, quic-proxy, china-dns-race-proxy, mosdns configs, and rules."
    warn "Xray binaries installed by the official installer are kept; remove Xray manually if you no longer need it."
    read -r -p "Are you sure? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Uninstall cancelled"; exit 0; }

    systemctl stop dnsdist mosdns sniproxy 5gpn-tcp-proxy quic-proxy china-dns-race-proxy 2>/dev/null || true
    systemctl disable dnsdist mosdns sniproxy 5gpn-tcp-proxy quic-proxy china-dns-race-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/{mosdns,sniproxy,5gpn-tcp-proxy,quic-proxy,china-dns-race-proxy,update-mosdns-rules}.*
    rm -rf /etc/systemd/system/dnsdist.service.d
    systemctl daemon-reload

    rm -rf "$BASE_DIR" /etc/sniproxy.conf /etc/mosdns /etc/dnsdist /usr/local/bin/update-mosdns-rules.sh
    rm -f /usr/local/sbin/sniproxy
    rm -f /etc/letsencrypt/renewal-hooks/deploy/99-reload-mosdns.sh
    rm -f /etc/sysctl.d/99-proxy-gateway.conf
    rm -f /etc/profile.d/go.sh

    # Optionally remove certbot certs
    warn "SSL certificates in /etc/letsencrypt/live/ are kept. Remove manually if needed."

    ok "Uninstall completed"
}

force_renew_cert() {
    if [[ -f "${CONF_DIR}/.domain" ]]; then
        DOMAIN=$(cat "${CONF_DIR}/.domain")
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        err "No domain found. Cannot renew."
        exit 1
    fi

    local certbot_cmd
    certbot_cmd=(certbot certonly --standalone -d "$DOMAIN" --force-renewal \
        --agree-tos -n -m "${EMAIL:-admin@${DOMAIN}}" \
        --pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh \
        --post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh)

    open_cert_http_port
    trap restore_reverse_proxy_firewall RETURN

    if ! "${certbot_cmd[@]}"; then
        # Check for known Python compatibility error
        if certbot --version 2>&1 | grep -q "AttributeError" || \
           "${certbot_cmd[@]}" 2>&1 | grep -q "AttributeError"; then
            warn "Certbot compatibility error detected. Attempting to fix Python dependencies..."
            ensure_pip3_available
            pip3 install --upgrade --break-system-packages certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || \
                pip3 install --upgrade certbot josepy cryptography >>"${INSTALL_LOG:-/tmp/5gpn-install.log}" 2>&1 || true
            info "Retrying certificate renewal..."
            "${certbot_cmd[@]}" || { err "Certificate renewal failed"; exit 1; }
        else
            err "Certificate renewal failed"
            exit 1
        fi
    fi

    # Re-copy certificates to mosdns-readable location
    local cert_live_dir="/etc/letsencrypt/live/${DOMAIN}"
    if [[ -d "$cert_live_dir" ]]; then
        copy_mosdns_cert "$DOMAIN"
    fi

    if systemctl is-active --quiet mosdns; then
        systemctl restart mosdns
        if systemctl is-active --quiet dnsdist; then
            systemctl reload dnsdist 2>/dev/null || systemctl restart dnsdist 2>/dev/null || true
        fi
        ok "Certificate renewed; mosdns restarted and dnsdist reloaded"
    else
        systemctl start mosdns
        systemctl restart dnsdist 2>/dev/null || true
        ok "Certificate renewed; mosdns started and dnsdist refreshed"
    fi
}

# =============================================================================
# Main installation flow
# =============================================================================
main_install() {
    bootstrap_remote_project "$@"
    check_root
    setup_install_log
    banner

    phase "Preflight checks"
    detect_os
    get_public_ip
    note "Gateway role: mosdns policy on :53 plus dnsdist DoT frontend on :853, TCP proxy on :80/:443, QUIC proxy on UDP :443."

    phase "Install system dependencies"
    install_deps

    phase "Prepare DNS control plane"
    check_port_53
    generate_domain
    verify_domain_resolution

    phase "Issue and stage TLS certificate"
    install_cert

    phase "Configure resolver policy"
    configure_overseas_dns
    configure_npn_client_cidrs

    phase "Configure proxy egress policy"
    configure_egress_policy
    configure_xray_policy

    phase "Build and install proxy services"
    install_xray_if_requested
    install_sniproxy
    install_5gpn_tcp_proxy
    install_quic_proxy
    install_china_dns_race_proxy

    phase "Render mosdns and bootstrap rule lists"
    install_mosdns
    install_dnsdist_frontend
    init_rules

    phase "Apply host tuning and firewall policy"
    system_tuning
    configure_ssh_policy
    configure_ssh_port
    setup_firewall

    phase "Start services and schedules"
    start_services
    setup_schedules

    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  Deployment complete${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
    echo "DoT endpoint: tls://${DOMAIN}:853"
    if [[ "$EGRESS_MODE" == "socks5" ]]; then
        echo "TCP proxy:   ${PUBLIC_IP}:80, ${PUBLIC_IP}:443 (5gpn-tcp-proxy -> ${EGRESS_SOCKS5_ADDR})"
    else
        echo "TCP proxy:   ${PUBLIC_IP}:80, ${PUBLIC_IP}:443 (sniproxy)"
    fi
    echo "UDP proxy:   ${PUBLIC_IP}:443 (quic-proxy)"
    echo "DNS service: ${PUBLIC_IP}:53"
    echo "Install log: ${INSTALL_LOG:-${LOG_DIR}/install-*.log}"
    echo ""
    echo "Client example (Android Private DNS):"
    echo "  ${DOMAIN}"
    echo ""
    echo "Management commands:"
    echo "  $0 --status"
    echo "  $0 --update-rules"
    echo "  $0 --renew-cert"
    echo "  $0 --uninstall"
    echo "============================================================"
}

# =============================================================================
# Entrypoint
# =============================================================================
case "${1:-}" in
    --status)
        get_public_ip 2>/dev/null || true
        show_status
        ;;
    --update-rules)
        /usr/local/bin/update-mosdns-rules.sh
        ;;
    --renew-cert)
        force_renew_cert
        ;;
    --uninstall)
        do_uninstall
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        main_install
        ;;
esac
