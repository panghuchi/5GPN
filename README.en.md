# 5GPN 5G Private-Network Smart DNS and SNI Reverse Proxy Gateway

[中文](README.md) | [English](README.en.md)

5GPN is a lightweight edge gateway for 5G NPN / N6 interconnection scenarios. It runs on a VPS or edge server: dnsdist terminates Android Private DNS / DoT on port 853, mosdns handles DNS split routing, sniproxy or 5gpn-tcp-proxy handles TCP 80/443 SNI/Host reverse proxying, quic-proxy covers UDP 443 QUIC/HTTP3 traffic, and china-dns-race-proxy races domestic DNS resolvers with overseas fallback.

## Architecture

```text
UE / terminal
  -> 5G private network / N6
  -> dnsdist :853 -> mosdns 127.0.0.1:5353/5354
  -> mosdns :53
      -> proxy domains: return VPS IP -> sniproxy or 5gpn-tcp-proxy / quic-proxy
      -> china domains: 127.0.0.1:5301 -> china-dns-race-proxy
      -> direct/default: overseas DNS pool
```

## Requirements

| Item | Requirement |
|------|-------------|
| OS | Ubuntu 20.04/22.04/24.04, Debian 11/12/13, CentOS/Stream 7/8/9, AlmaLinux/Rocky/RHEL 8/9, Fedora 39+ |
| CPU | x86_64 (`amd64`) or ARM64 (`aarch64`) |
| Memory | 512 MB or more recommended |
| Network | Public IPv4, with your domain A record pointing to that IP |
| Privilege | Must run as `root` |

The installer uses nftables for firewall management. SSH stays on port `22` by default, and interactive installation can change it.

## Components

| Component | Protocol/Port | Role |
|-----------|---------------|------|
| dnsdist | TCP 853 | Android Private DNS / DoT TLS frontend |
| mosdns | TCP/UDP 53, TCP/UDP 127.0.0.1:5353/5354 | Smart DNS split-routing engine |
| sniproxy | TCP 80/443 | Default `direct` TCP HTTP/HTTPS SNI/Host reverse proxy |
| 5gpn-tcp-proxy | TCP 80/443 | Optional TCP HTTP/HTTPS SNI/Host proxy through SOCKS5 egress |
| quic-proxy | UDP 443 | QUIC/HTTP3 SNI reverse proxy |
| china-dns-race-proxy | TCP/UDP 127.0.0.1:5301 | Domestic DNS racing, TCP retry, and overseas fallback |
| Certbot | - | Let's Encrypt certificate issuance and renewal |

## Access Policy

- DNS 53: only `172.22.0.0/16` may access it.
- DoT 853: open to all sources, but only `172.22.0.0/16` receives proxy-spoofed answers.
- TCP 80/443: only `172.22.0.0/16` may access sniproxy or 5gpn-tcp-proxy.
- UDP 443: only `172.22.0.0/16` may access quic-proxy.
- SSH: port `22` by default; interactive installation can change it.

| Source IP | proxy/GFWList domains | china/ChinaList domains | direct/default domains |
|-----------|-----------------------|--------------------------|------------------------|
| `172.22.0.0/16` | Return VPS IP and enter TCP/QUIC proxying | Use local China DNS race proxy | A queries return VPS IP by default and enter TCP/QUIC proxying |
| Other sources | Do not return VPS IP; resolve normally | Use local China DNS race proxy | Use public overseas DNS pool |

DNS does not return AAAA records by default, so clients use IPv4 only.

## Quick Start

### One-Line Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

Without `curl`:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

### Manual Install

```bash
chmod +x install.sh
./install.sh
```

The installer handles dependencies, domain verification, Let's Encrypt issuance, dnsdist/mosdns/sniproxy/quic-proxy/china-dns-race-proxy installation, initial rules, nftables firewall policy, host tuning, scheduled certificate renewal, and scheduled rule updates.

## Domain Setup

Prepare your own domain and point its A record to the VPS public IPv4:

```text
dot.example.com  A  <VPS public IPv4>
```

Non-interactive example:

```bash
export DOMAIN="dot.example.com"
export EMAIL="admin@example.com"
./install.sh
```

If DNS propagation has not completed yet, or if your DNS environment is special:

```bash
export DOMAIN="dot.example.com"
export SKIP_DNS_CHECK=1
./install.sh
```

## DNS Upstreams

```bash
export PRIVATE_OVERSEAS_DNS="22.22.22.22"
export PUBLIC_OVERSEAS_DNS="1.1.1.1,8.8.8.8"
export SNIPROXY_DNS="22.22.22.22"
export NPN_CLIENT_CIDRS="172.22.0.0/16"
./install.sh
```

- `NPN_CLIENT_CIDRS`: CIDRs treated as private-network DNS clients by mosdns. Defaults to `172.22.0.0/16`; add more CIDRs if DoT queries arrive from another private/NAT segment.
- `PRIVATE_OVERSEAS_DNS`: default overseas resolver pool for private-network clients.
- `PUBLIC_OVERSEAS_DNS`: default overseas resolver pool for non-private DoT clients.
- `SNIPROXY_DNS`: resolver used by sniproxy backends. Defaults to `PRIVATE_OVERSEAS_DNS`.
- `EGRESS_MODE`: proxy egress mode. `direct` uses sniproxy/quic-proxy directly; `socks5` uses 5gpn-tcp-proxy/quic-proxy through SOCKS5.
- `EGRESS_SOCKS5_ADDR`: local SOCKS5 egress address when `EGRESS_MODE=socks5`. Defaults to `127.0.0.1:1080`.
- `OVERSEAS_DNS`: legacy alias for `PRIVATE_OVERSEAS_DNS`.

The values are stored under `/etc/mosdns/.overseas_private_dns`, `/etc/mosdns/.overseas_public_dns`, and `/etc/mosdns/.sniproxy_dns`.

## Custom Split Rules and Subscriptions

Local rule files:

| Type | File | Behavior |
|------|------|----------|
| proxy | `/etc/mosdns/rules/custom/proxy.txt` | Private clients receive VPS IP and enter sniproxy/quic-proxy |
| direct | `/etc/mosdns/rules/custom/direct.txt` | Force real overseas DNS resolution |
| china | `/etc/mosdns/rules/custom/china.txt` | Force local China DNS race proxy |
| reject | `/etc/mosdns/rules/custom/reject.txt` | Reject resolution |

Subscription URL files:

| Type | File |
|------|------|
| proxy | `/etc/mosdns/subscriptions/proxy-urls.txt` |
| direct | `/etc/mosdns/subscriptions/direct-urls.txt` |
| china | `/etc/mosdns/subscriptions/china-urls.txt` |
| reject | `/etc/mosdns/subscriptions/reject-urls.txt` |

Each line is a subscription URL. Downloaded content can be plain domain lists, Adblock style `||example.com^`, Clash/Surge/Quantumult rules such as `DOMAIN,example.com,Proxy`, `DOMAIN-SUFFIX,example.com,Proxy`, `DOMAIN-KEYWORD,example.com,Proxy`, or dnsmasq style `server=/example.com/114.114.114.114`, `address=/example.com/1.2.3.4`, `ipset=/example.com/tag`. The updater normalizes, merges, and deduplicates domains:

```bash
./install.sh --update-rules
```

## Management Commands

```bash
./install.sh --status          # Show service status
./install.sh --update-rules    # Update GFWList/ChinaList/custom subscriptions
./install.sh --renew-cert      # Renew certificates and restart mosdns
./install.sh --uninstall       # Uninstall components and configuration
```

## DNS Query Diagnostics

Per-query DNS logging is disabled by default to keep journals quiet. Enable it only while troubleshooting split routing:

```bash
echo 1 > /etc/mosdns/.query_log
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
journalctl -u mosdns -f
```

`5gpn-private` means the 5G private-network or local diagnostic entry. `5gpn-public` means the public DoT entry. The mosdns summary includes the query name, query type, and response records. Disable it after debugging:

```bash
echo 0 > /etc/mosdns/.query_log
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
```

If overseas domains show `5gpn-public` in logs, the DNS query did not match `NPN_CLIENT_CIDRS`; mosdns will return real public records instead of the VPS IP, so the VPS 443 proxy will not receive the connection. Capture the DNS source address first, then add the corresponding CIDR:

```bash
tcpdump -ni any 'port 53 or port 853'
echo '172.22.0.0/16,100.64.0.0/10' > /etc/mosdns/.npn_client_cidrs
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
```

## SOCKS5 Egress

During interactive installation, the script asks for proxy egress mode:

- `direct`: the VPS connects to target sites directly. TCP uses sniproxy and UDP/443 uses quic-proxy.
- `socks5`: TCP 80/443 and UDP/443 QUIC traffic are sent to a local SOCKS5 egress, such as `127.0.0.1:1080`.

By default, TCP 80/443 uses `sniproxy` and exits directly from the VPS. If Xray or sing-box exposes a local SOCKS5 listener, proxy-domain TCP traffic can use that egress:

```bash
export EGRESS_MODE=socks5
export EGRESS_SOCKS5_ADDR="127.0.0.1:1080"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

If the installer is also asked to install Xray, it uses the official installer and writes `/usr/local/etc/xray/config.json`. The Xray inbound listens on the configured SOCKS5 address, and the outbound is generated from the interactive SS2022 parameters:

```bash
export EGRESS_MODE=socks5
export EGRESS_SOCKS5_ADDR="127.0.0.1:1080"
export XRAY_INSTALL=yes
export SS2022_ADDRESS="64.118.147.55"
export SS2022_PORT="48086"
export SS2022_METHOD="2022-blake3-aes-128-gcm"
export SS2022_PASSWORD="your-password"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

### SS2022 Exit Management

Multiple SS2022 exits can be saved and switched after installation. The inventory lives in `/opt/proxy-gateway/etc/exits/*.json`, and the active exit name is stored in `/opt/proxy-gateway/etc/.current_exit`. Xray config renders only the currently selected exit, not the full inventory.

```bash
./install.sh --add-exit
./install.sh --list-exits
./install.sh --set-exit hk
./install.sh --delete-exit jp
```

`--add-exit` prompts for exit name, server address, port, method, and password. Non-interactive use can still pass `NAME ADDRESS PORT METHOD PASSWORD`.

`--set-exit` switches proxy egress to the local Xray SOCKS5 listener, rewrites `/usr/local/etc/xray/config.json` for the selected exit, and restarts Xray, `5gpn-tcp-proxy`, and `quic-proxy`.

`--delete-exit` deletes only inactive exits. Switch away from the active exit before deleting it.

SOCKS5 egress covers both TCP 80/443 and UDP/443 QUIC. The Xray/sing-box SOCKS5 inbound must enable UDP support, otherwise QUIC may fail or fall back to TCP.

## Key Files

| File | Description |
|------|-------------|
| `install.sh` | Main installer |
| `mosdns_config.yaml` | mosdns configuration template |
| `update-rules.sh` | Rule updater and subscription merger |
| `renew-hook.sh` | Certificate renewal hook |
| `sniproxy.conf` | sniproxy configuration template |
| `5gpn-tcp-proxy.go` | TCP Host/SNI proxy with `direct`/SOCKS5 egress support |
| `quic-proxy.go` | QUIC SNI proxy source |
| `china-dns-race-proxy.go` | China DNS race proxy source |

## Technical Notes

### mosdns Split Routing

dnsdist listens on public TCP 853, terminates DoT/TLS, and forwards queries to mosdns local private/public backends according to source CIDR. mosdns uses separate entries for plain DNS and DoT frontend traffic: plain DNS 53 rejects non-private sources, while dnsdist DoT 853 is public but does not return proxy IPs to public sources. For private clients, china/ChinaList domains resolve normally through the China path, direct domains are manual real-resolution exceptions, and all remaining A records return the VPS IP by default.

### China DNS

ChinaList and custom china domains are forwarded to `127.0.0.1:5301`. `china-dns-race-proxy` races `223.5.5.5` and `223.6.6.6` by default, starts domestic TCP 53 retry after `150ms`, and only enables overseas fallback after `750ms`, avoiding slowdowns from a single stalled domestic DNS resolver. Domestic queries inject EDNS Client Subnet `139.226.48.0/24` by default to help Chinese CDNs return China-friendly addresses. Override it in `/opt/proxy-gateway/etc/china-dns-race-proxy.env`:

```bash
CHINA_DNS_UPSTREAMS=223.5.5.5:53,223.6.6.6:53
CHINA_DNS_ECS=139.226.48.0/24
```

### TCP Proxy

sniproxy is built from source and installed to `/usr/local/sbin/sniproxy` to avoid distro package path and build-option differences. The installer generates `/etc/sniproxy.conf`, writes the upstream resolver from `SNIPROXY_DNS`, and forces `mode ipv4_only`. It does not decrypt TLS; it forwards by SNI/Host only.

### QUIC/HTTP3 Proxy

`quic-proxy` listens on UDP 443, parses TLS ClientHello SNI from QUIC v1 Initial packets, and forwards traffic to the real backend. Clients using incompatible QUIC versions usually fall back to TCP/HTTP2.

### Firewall

The script generates `/etc/nftables.conf` with `table ip nat` and `table ip filter`. Reverse proxy ports keep the private-network whitelist:

```nft
ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept
ip saddr 172.22.0.0/16 udp dport 443 accept
```

## Troubleshooting

```bash
# Service status
systemctl status dnsdist
systemctl status mosdns
systemctl status sniproxy
systemctl status quic-proxy
systemctl status china-dns-race-proxy

# Live logs
journalctl -u dnsdist -f
journalctl -u mosdns -f
journalctl -u sniproxy -f
journalctl -u quic-proxy -f
journalctl -u china-dns-race-proxy -f

# Test DoT
dig +tls @dot.example.com -p 853 youtube.com

# Test TCP reverse proxy
curl -I --resolve youtube.com:443:<VPS_IP> https://youtube.com
```

## Security Notes

This project is intended for legitimate enterprise cross-border connectivity. A dedicated domain and private-network port restrictions reduce accidental exposure, but cannot fully eliminate the possibility of active probing, IP blocking, or abuse.
