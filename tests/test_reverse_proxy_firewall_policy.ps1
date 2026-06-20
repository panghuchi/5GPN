$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$install = Get-Content -Path (Join-Path $root "install.sh") -Raw -Encoding UTF8
$readme = Get-Content -Path (Join-Path $root "README.md") -Raw -Encoding UTF8

function Assert-Contains {
    param(
        [string]$Haystack,
        [string]$Needle,
        [string]$Description
    )

    if (-not $Haystack.Contains($Needle)) {
        throw "Missing reverse proxy firewall marker: $Description ($Needle)"
    }
}

Assert-Contains $install 'ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept' 'nft TCP reverse proxy private allow'
Assert-Contains $install 'ip saddr 172.22.0.0/16 udp dport 443 accept' 'nft UDP reverse proxy private allow'
Assert-Contains $install 'table ip nat {' 'nft nat table exists'
Assert-Contains $install 'table ip filter {' 'nft ip filter table exists'
Assert-Contains $install 'type filter hook input priority filter; policy drop;' 'nft input default drop'
Assert-Contains $install 'SSH_PORT="${SSH_PORT:-26941}"' 'default SSH port variable'
Assert-Contains $install 'configure_ssh_port()' 'SSH daemon port configuration function'
Assert-Contains $install 'Port ${SSH_PORT}' 'SSH daemon port drop-in'
Assert-Contains $install 'sshd -t' 'SSH daemon config validation'
Assert-Contains $install 'tcp dport 26941 accept' 'SSH custom port allow'
Assert-Contains $install 'ip saddr 172.22.0.0/16 tcp dport 53 accept' 'nft DNS/53 TCP private allow'
Assert-Contains $install 'ip saddr 172.22.0.0/16 udp dport 53 accept' 'nft DNS/53 UDP private allow'
Assert-Contains $install 'tcp dport 853 accept' 'DoT public allow'
Assert-Contains $install 'comment "proxy-gateway-cert-http"' 'temporary HTTP rule is tagged'
Assert-Contains $install 'open_cert_http_port()' 'cert flow opens HTTP-01 port temporarily'
Assert-Contains $install 'restore_reverse_proxy_firewall()' 'cert flow restores reverse proxy whitelist'
Assert-Contains $install '--pre-hook /usr/local/bin/proxy-gateway-open-cert-http.sh' 'certbot pre-hook opens port 80'
Assert-Contains $install '--post-hook /usr/local/bin/proxy-gateway-restore-firewall.sh' 'certbot post-hook restores firewall'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/pre/10-proxy-gateway-open-http.sh' 'automatic renew pre-hook'
Assert-Contains $install '/etc/letsencrypt/renewal-hooks/post/90-proxy-gateway-restore-firewall.sh' 'automatic renew post-hook'
Assert-Contains $install 'Firewall configured (reverse proxy whitelist: 172.22.0.0/16)' 'firewall status message'
Assert-Contains $readme '172.22.0.0/16' 'README documents reverse proxy whitelist'
Assert-Contains $readme '80/443' 'README documents reverse proxy ports'
Assert-Contains $readme '443' 'README documents reverse proxy port'

if ($install.Contains('tcp dport 22 accept') -or $install.Contains('tcp dport 8111 accept')) {
    throw "Firewall must not open default SSH 22 or old iOS profile 8111 ports"
}

Write-Output "reverse proxy firewall markers OK"
