$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$templatePath = Join-Path $root "mosdns_config.yaml"
$template = Get-Content -Path $templatePath -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Needle, [string]$Description)
    if (-not $template.Contains($Needle)) { throw "Missing mosdns policy marker: $Description ($Needle)" }
}

Assert-Contains 'http: "127.0.0.1:8080"' 'local-only mosdns API'
Assert-Contains 'type: ip_set' 'private source network set'
Assert-Contains '172.22.0.0/16' 'NPN client CIDR'
Assert-Contains 'tag: plain_dns_entry' 'separate plain DNS entry'
Assert-Contains '"!client_ip $npn_clients"' 'non-NPN DNS/53 rejection'
Assert-Contains 'tag: dot_entry' 'separate DoT entry'
Assert-Contains 'client_ip $npn_clients' 'DoT source-aware split'
Assert-Contains 'black_hole __SERVER_IP__' 'private-client proxy spoof'
Assert-Contains 'tag: private_overseas' 'private overseas pool'
Assert-Contains 'tag: public_overseas' 'public overseas pool'
Assert-Contains 'udp://127.0.0.1:5301' 'ChinaList uses local race proxy'
Assert-Contains 'qtype 28' 'AAAA IPv4-only handling'
Assert-Contains 'cert: "/etc/mosdns/certs/fullchain.pem"' 'DoT certificate path'

Write-Output "mosdns policy markers OK"
