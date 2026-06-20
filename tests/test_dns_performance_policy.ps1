$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$template = Get-Content -Path (Join-Path $root "mosdns_config.yaml") -Raw -Encoding UTF8
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Description)
    if (-not $Haystack.Contains($Needle)) { throw "Missing DNS performance marker: $Description ($Needle)" }
}

Assert-Contains $template 'production: false' 'human-readable logs during deployment'
Assert-Contains $template '127.0.0.1:8080' 'local-only API endpoint'
Assert-Contains $install 'LimitNOFILE=1048576' 'high file descriptor limit for mosdns'
Assert-Contains $install 'Restart=on-failure' 'mosdns restart policy'
Assert-Contains $install 'AmbientCapabilities=CAP_NET_BIND_SERVICE' 'privileged port binding capability'

Write-Output "DNS performance markers OK"
