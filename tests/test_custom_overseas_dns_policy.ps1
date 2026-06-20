$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$template = Get-Content -Path (Join-Path $root "mosdns_config.yaml") -Raw -Encoding UTF8
$rules = Get-Content -Path (Join-Path $root "update-rules.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Description)
    if (-not $Haystack.Contains($Needle)) { throw "Missing custom overseas DNS marker: $Description ($Needle)" }
}

Assert-Contains $install 'DEFAULT_OVERSEAS_DNS=("1.1.1.1" "8.8.8.8" "9.9.9.9")' 'default overseas DNS array'
Assert-Contains $install 'configure_overseas_dns()' 'installer overseas DNS function'
Assert-Contains $install 'PRIVATE_OVERSEAS_DNS' 'installer private overseas DNS variable'
Assert-Contains $install 'PUBLIC_OVERSEAS_DNS' 'installer public overseas DNS variable'
Assert-Contains $install 'SNIPROXY_DNS' 'installer sniproxy DNS variable'
Assert-Contains $install 'NPN_CLIENT_CIDRS' 'installer NPN client CIDR variable'
Assert-Contains $install 'configure_npn_client_cidrs()' 'installer NPN client CIDR prompt'
Assert-Contains $install '/etc/mosdns/.overseas_private_dns' 'installer saves private overseas DNS config'
Assert-Contains $install '/etc/mosdns/.overseas_public_dns' 'installer saves public overseas DNS config'
Assert-Contains $install '/etc/mosdns/.npn_client_cidrs' 'installer saves NPN client CIDR config'
Assert-Contains $template '__NPN_CLIENT_CIDRS__' 'mosdns NPN client CIDR placeholder'
Assert-Contains $template '__PRIVATE_OVERSEAS_UPSTREAMS__' 'mosdns private overseas placeholder'
Assert-Contains $template '__PUBLIC_OVERSEAS_UPSTREAMS__' 'mosdns public overseas placeholder'
Assert-Contains $rules '.npn_client_cidrs' 'rule updater reads saved NPN client CIDR config'
Assert-Contains $rules '__NPN_CLIENT_CIDRS__' 'rule updater replaces NPN client CIDR placeholder'
Assert-Contains $rules '.overseas_private_dns' 'rule updater reads saved private overseas DNS config'
Assert-Contains $rules '.overseas_public_dns' 'rule updater reads saved public overseas DNS config'
Assert-Contains $rules '__PRIVATE_OVERSEAS_UPSTREAMS__' 'rule updater replaces private overseas placeholder'
Assert-Contains $rules '__PUBLIC_OVERSEAS_UPSTREAMS__' 'rule updater replaces public overseas placeholder'
Assert-Contains $readme 'PRIVATE_OVERSEAS_DNS' 'README documents private overseas DNS variable'
Assert-Contains $readme 'PUBLIC_OVERSEAS_DNS' 'README documents public overseas DNS variable'
Assert-Contains $readme 'SNIPROXY_DNS' 'README documents sniproxy DNS variable'
Assert-Contains $readme 'NPN_CLIENT_CIDRS' 'README documents NPN client CIDR variable'

Write-Output "custom overseas DNS markers OK"
