$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$installPath = Join-Path $root "install.sh"
$install = Get-Content -Path $installPath -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Needle,
        [string]$Description
    )

    if (-not $install.Contains($Needle)) {
        throw "Missing noninteractive domain marker: $Description ($Needle)"
    }
}

Assert-Contains 'DOMAIN_PRECONFIGURED=1' 'preconfigured domain flag'
Assert-Contains 'DOMAIN is required in non-interactive mode.' 'noninteractive install requires an operator-owned domain'
Assert-Contains 'verify_domain_resolution()' 'self-managed domain DNS verification function'
Assert-Contains 'SKIP_DNS_CHECK' 'optional DNS verification bypass'

if ($install.Contains('register_domain_cloudns()') -or $install.Contains('CLOUDNS_ID') -or $install.Contains('CLOUDNS_PASS')) {
    throw "install.sh must not require or advertise ClouDNS integration"
}

if ($install.Contains('python3-certbot-dns-cloudflare') -or $install.Contains('python3-cloudflare')) {
    throw "install.sh must not install DNS-provider certbot plugins in self-managed domain mode"
}

Write-Output "noninteractive domain markers OK"
