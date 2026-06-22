#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

sample="${tmpdir}/rules.txt"
output="${tmpdir}/normalized.txt"

cat > "${sample}" <<'EOF'
# plain domains
Example.COM
*.Wildcard.Example
.Dot.Example
www.Trimmed.Example

# Adblock style
||Adblock.Example^

# Clash / Surge / Quantumult style
DOMAIN,Exact.Example,Proxy
DOMAIN-SUFFIX,Suffix.Example,DIRECT
DOMAIN-KEYWORD,Keyword.Example,Proxy
- DOMAIN,Yaml.Example,Proxy
HOST,Host.Example,Proxy
HOST-SUFFIX,HostSuffix.Example,Proxy

# dnsmasq style
server=/Dnsmasq.Example/114.114.114.114
address=/Address.Example/1.2.3.4
ipset=/Ipset.Example/proxy
nftset=/Nftset.Example/4#inet#fw4#proxy

# unsupported lines should be ignored
IP-CIDR,1.2.3.0/24,Proxy
[AutoProxy 0.2.9]
! comment
EOF

funcs="${tmpdir}/functions.sh"
sed -n '/^trim_domain()/,/^render_mosdns_upstreams()/p' "${root}/update-rules.sh" | sed '$d' > "${funcs}"
bash -c 'source "$1"; normalize_domain_file "$2" "$3"' _ "${funcs}" "${sample}" "${output}"
sort -u "${output}" > "${output}.sorted"

expected="${tmpdir}/expected.txt"
cat > "${expected}" <<'EOF'
adblock.example
address.example
dnsmasq.example
dot.example
exact.example
example.com
host.example
hostsuffix.example
ipset.example
keyword.example
nftset.example
suffix.example
trimmed.example
wildcard.example
yaml.example
EOF

diff -u "${expected}" "${output}.sorted"
echo "subscription rule format policy OK"
