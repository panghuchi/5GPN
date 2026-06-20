$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8
$proxy = Get-Content -Path (Join-Path $root "5gpn-tcp-proxy.go") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Description)
    if (-not $Haystack.Contains($Needle)) { throw "Missing TCP egress marker: $Description ($Needle)" }
}

Assert-Contains $install '"5gpn-tcp-proxy.go"' 'remote bootstrap includes TCP proxy source'
Assert-Contains $install 'install_5gpn_tcp_proxy()' 'installer builds TCP proxy'
Assert-Contains $install 'EGRESS_MODE="${EGRESS_MODE:-direct}"' 'direct egress default'
Assert-Contains $install 'EGRESS_SOCKS5_ADDR="${EGRESS_SOCKS5_ADDR:-127.0.0.1:1080}"' 'SOCKS5 default address'
Assert-Contains $install 'systemctl restart 5gpn-tcp-proxy' 'socks5 mode starts TCP proxy'
Assert-Contains $install 'systemctl stop sniproxy' 'socks5 mode stops sniproxy to avoid port conflict'
Assert-Contains $install 'systemctl restart sniproxy' 'direct mode keeps sniproxy'
Assert-Contains $install '/opt/proxy-gateway/etc/egress.env' 'egress env file'
Assert-Contains $proxy 'dialSOCKS5' 'SOCKS5 outbound implementation'
Assert-Contains $proxy 'parseTLSSNI' 'TLS SNI parser'
Assert-Contains $proxy 'parseHTTPHost' 'HTTP Host parser'
Assert-Contains $readme 'EGRESS_MODE=socks5' 'README documents SOCKS5 egress'

Write-Output "TCP proxy egress markers OK"
