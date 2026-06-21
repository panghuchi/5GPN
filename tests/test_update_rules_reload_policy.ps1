$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$rules = Get-Content -Path (Join-Path $root "update-rules.sh") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Needle, [string]$Description)
    if (-not $rules.Contains($Needle)) { throw "Missing update-rules reload marker: $Description ($Needle)" }
}

Assert-Contains 'reload_mosdns()' 'mosdns reload function'
Assert-Contains 'systemctl restart mosdns' 'restart active mosdns after rule update'
Assert-Contains 'systemctl start mosdns' 'start mosdns if inactive'
Assert-Contains 'install_dnsdist_config()' 'dnsdist frontend config render function'
Assert-Contains 'dnsdist frontend refreshed' 'refresh dnsdist frontend after mosdns update'
Assert-Contains '__NPN_CLIENT_CIDRS_LUA__' 'render dnsdist NPN client CIDRs'
Assert-Contains 'DNS_QUERY_LOG' 'optional query summary log switch'
Assert-Contains 'query_summary %s' 'query summary executable'
Assert-Contains '5gpn-private' 'private query summary marker'
Assert-Contains '5gpn-public' 'public query summary marker'
Assert-Contains 'subscriptions' 'subscription URL support'
Assert-Contains 'custom' 'custom local rule support'

Write-Output "update-rules reload markers OK"
