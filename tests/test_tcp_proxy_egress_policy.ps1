$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8
$proxy = Get-Content -Path (Join-Path $root "5gpn-tcp-proxy.go") -Raw -Encoding UTF8
$quic = Get-Content -Path (Join-Path $root "quic-proxy.go") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Description)
    if (-not $Haystack.Contains($Needle)) { throw "Missing TCP egress marker: $Description ($Needle)" }
}

Assert-Contains $install '"5gpn-tcp-proxy.go"' 'remote bootstrap includes TCP proxy source'
Assert-Contains $install 'install_5gpn_tcp_proxy()' 'installer builds TCP proxy'
Assert-Contains $install 'configure_egress_policy()' 'installer prompts for egress mode'
Assert-Contains $install 'Select proxy egress mode [direct/socks5' 'interactive egress mode selector'
Assert-Contains $install 'SOCKS5 outbound address, ip:port' 'interactive SOCKS5 address prompt'
Assert-Contains $install 'validate_socks5_addr()' 'SOCKS5 address validation'
Assert-Contains $install 'configure_xray_policy()' 'optional Xray policy prompt'
Assert-Contains $install 'xray_installed()' 'Xray installed detection'
Assert-Contains $install 'install_xray_if_requested()' 'optional Xray installer'
Assert-Contains $install 'Existing Xray installation detected; skipping official installer.' 'Xray installer skip path'
Assert-Contains $install 'https://github.com/XTLS/Xray-install/raw/main/install-release.sh' 'official Xray installer URL'
Assert-Contains $install '/usr/local/etc/xray/config.json' 'Xray config path'
Assert-Contains $install 'split_host_port "$EGRESS_SOCKS5_ADDR" inbound_host inbound_port' 'Xray inbound follows SOCKS5 address'
Assert-Contains $install 'SS2022_ADDRESS is required when XRAY_INSTALL=yes' 'required SS2022 address'
Assert-Contains $install 'SS2022_METHOD is required when XRAY_INSTALL=yes' 'required SS2022 method'
Assert-Contains $install '"protocol": "shadowsocks"' 'Xray shadowsocks outbound'
Assert-Contains $install 'EGRESS_MODE="${EGRESS_MODE:-direct}"' 'direct egress default'
Assert-Contains $install 'EGRESS_SOCKS5_ADDR="${EGRESS_SOCKS5_ADDR:-127.0.0.1:1080}"' 'SOCKS5 default address'
Assert-Contains $install 'systemctl restart 5gpn-tcp-proxy' 'socks5 mode starts TCP proxy'
Assert-Contains $install 'systemctl stop sniproxy' 'socks5 mode stops sniproxy to avoid port conflict'
Assert-Contains $install 'systemctl restart sniproxy' 'direct mode keeps sniproxy'
Assert-Contains $install '/opt/proxy-gateway/etc/egress.env' 'egress env file'
Assert-Contains $install 'quic-proxy -l 0.0.0.0:443 -egress=${EGRESS_MODE}' 'quic-proxy receives egress mode'
if ($install.Contains('quic-proxy already compiled')) {
    throw "install.sh must rebuild quic-proxy when service flags change"
}
Assert-Contains $proxy 'dialSOCKS5' 'SOCKS5 outbound implementation'
Assert-Contains $proxy 'parseTLSSNI' 'TLS SNI parser'
Assert-Contains $proxy 'parseHTTPHost' 'HTTP Host parser'
Assert-Contains $quic 'dialSOCKS5UDPAssociate' 'SOCKS5 UDP associate implementation'
Assert-Contains $quic 'wrapSOCKS5UDP' 'SOCKS5 UDP packet wrapper'
Assert-Contains $quic 'unwrapSOCKS5UDP' 'SOCKS5 UDP packet unwrapper'
Assert-Contains $readme 'EGRESS_MODE=socks5' 'README documents SOCKS5 egress'
Assert-Contains $readme 'XRAY_INSTALL=yes' 'README documents optional Xray install'
Assert-Contains $readme 'SS2022_METHOD' 'README documents SS2022 method'
Assert-Contains $readme 'UDP/443 QUIC' 'README documents UDP SOCKS5 egress'

Write-Output "TCP proxy egress markers OK"
