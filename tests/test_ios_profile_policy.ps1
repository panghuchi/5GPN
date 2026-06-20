$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-NotContains {
    param([string]$Haystack, [string]$Needle, [string]$Description)
    if ($Haystack.Contains($Needle)) { throw "Unexpected iOS/profile marker remains: $Description ($Needle)" }
}

Assert-NotContains $install 'IOS_PROFILE_PORT=8111' 'iOS profile port'
Assert-NotContains $install 'generate_ios_profile()' 'iOS profile generator function'
Assert-NotContains $install 'proxy-gateway-ios-profile.service' 'iOS profile service'
Assert-NotContains $install 'http.server' 'Python static profile server'
Assert-NotContains $install '-ios)' 'iOS CLI dispatch'
Assert-NotContains $install 'qrencode' 'QR encoder package for removed iOS profile output'
Assert-NotContains $readme ':8111/ios-dot.mobileconfig' 'README iOS URL'
Assert-NotContains $readme './install.sh -ios' 'README iOS command'
Assert-NotContains $readme 'iOS 描述文件' 'README iOS profile section'

Write-Output "iOS profile removal markers OK"
