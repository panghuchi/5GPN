$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$templatePath = Join-Path $root "mosdns_config.yaml"
$template = Get-Content -Path $templatePath -Raw -Encoding UTF8
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$rules = Get-Content -Path (Join-Path $root "update-rules.sh") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Needle, [string]$Description)
    if (-not $template.Contains($Needle)) { throw "Missing mosdns policy marker: $Description ($Needle)" }
}

Assert-Contains 'http: "127.0.0.1:8080"' 'local-only mosdns API'
$templateHeader = ($template -split "`n" | Select-Object -First 15) -join "`n"
if ($templateHeader.Contains('__SERVER_IP__') -or
    $templateHeader.Contains('__PRIVATE_OVERSEAS_UPSTREAMS__') -or
    $templateHeader.Contains('__PUBLIC_OVERSEAS_UPSTREAMS__')) {
    throw "mosdns template header must not contain render placeholders because replacements are global"
}
if ($template.Contains('include: []')) {
    throw "mosdns template must not use include: [] because mosdns v5 expects include to be a map"
}
if (-not $install.Contains('content = content.replace("\ninclude: []\n", "\n")')) {
    throw "install.sh must scrub stale include: [] from rendered mosdns config"
}
if (-not $rules.Contains("content = content.replace('\ninclude: []\n', '\n')")) {
    throw "update-rules.sh must scrub stale include: [] from rendered mosdns config"
}
Assert-Contains 'type: ip_set' 'private source network set'
Assert-Contains '__NPN_CLIENT_CIDRS__' 'rendered NPN client CIDR list'
if (-not $install.Contains('DEFAULT_NPN_CLIENT_CIDRS=("172.22.0.0/16")')) {
    throw "install.sh must keep 172.22.0.0/16 as the default NPN client CIDR"
}
if (-not $install.Contains('127.0.0.1/32')) {
    throw "install.sh must keep loopback in rendered NPN client CIDRs for local diagnostics"
}
if (-not $rules.Contains('.npn_client_cidrs')) {
    throw "update-rules.sh must preserve saved NPN client CIDRs"
}
Assert-Contains 'tag: plain_dns_entry' 'separate plain DNS entry'
Assert-Contains '"!client_ip $npn_clients"' 'non-NPN DNS/53 rejection'
Assert-Contains 'tag: dot_entry' 'separate DoT entry'
Assert-Contains 'client_ip $npn_clients' 'DoT source-aware split'
Assert-Contains 'black_hole __SERVER_IP__' 'private-client proxy spoof'
if (-not $template.Contains('Default for private clients: any remaining A query is treated as proxy')) {
    throw "mosdns private sequence must default remaining A queries to the VPS proxy"
}
if (-not $template.Contains('- matches: qtype 1') -or -not $template.Contains('exec: black_hole __SERVER_IP__')) {
    throw "mosdns private sequence must blackhole default A queries to the VPS IP"
}
Assert-Contains 'tag: private_overseas' 'private overseas pool'
Assert-Contains 'tag: public_overseas' 'public overseas pool'
Assert-Contains '__PRIVATE_QUERY_LOG_RULE__' 'private query log placeholder'
Assert-Contains '__PUBLIC_QUERY_LOG_RULE__' 'public query log placeholder'
Assert-Contains 'udp://127.0.0.1:5301' 'ChinaList uses local race proxy'
Assert-Contains 'qtype 28' 'AAAA IPv4-only handling'
Assert-Contains 'cert: "/etc/mosdns/certs/fullchain.pem"' 'DoT certificate path'

Write-Output "mosdns policy markers OK"
