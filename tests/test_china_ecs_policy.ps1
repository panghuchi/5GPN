$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$template = Get-Content -Path (Join-Path $root "mosdns_config.yaml") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Needle, [string]$Description)
    if (-not $template.Contains($Needle)) { throw "Missing China routing marker: $Description ($Needle)" }
}

Assert-Contains 'tag: china_domains' 'China domain set'
Assert-Contains '/etc/mosdns/rules/chinalist.txt' 'generated ChinaList rule file'
Assert-Contains '/etc/mosdns/rules/china-domains.txt' 'custom China rule file'
Assert-Contains 'tag: china_race' 'local China race upstream'
Assert-Contains 'udp://127.0.0.1:5301' 'China queries use local race proxy'

Write-Output "China routing markers OK"
