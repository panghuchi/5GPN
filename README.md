# 5GPN 5G 专网智能 DNS 与 SNI 透明反代网关

5GPN 面向 5G NPN / N6 互通场景，在 VPS 或边缘服务器上部署一套轻量出口网关：dnsdist 负责 Android Private DNS / DoT 853 前端，mosdns 负责 DNS 分流策略，sniproxy 或 5gpn-tcp-proxy 负责 TCP 80/443 的 SNI/Host 透明反代，quic-proxy 补齐 UDP 443 的 QUIC/HTTP3 场景，china-dns-race-proxy 负责国内域名解析竞速与 fallback。

## 架构概览

```text
UE / 终端
  -> 5G 专网 / N6
  -> dnsdist :853 -> mosdns 127.0.0.1:5353/5354
  -> mosdns :53
      -> proxy 域名: 返回 VPS IP -> sniproxy 或 5gpn-tcp-proxy / quic-proxy
      -> china 域名: 127.0.0.1:5301 -> china-dns-race-proxy
      -> direct/默认: 海外 DNS 池
```

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Ubuntu 20.04/22.04/24.04, Debian 11/12/13, CentOS/Stream 7/8/9, AlmaLinux/Rocky/RHEL 8/9, Fedora 39+ |
| CPU | x86_64 (`amd64`) 或 ARM64 (`aarch64`) |
| 内存 | 建议 512 MB 以上 |
| 网络 | 公网 IPv4，域名 A 记录指向该 IP |
| 权限 | 必须以 `root` 运行 |

安装脚本默认使用 nftables 管理防火墙，并默认保留 SSH 端口 `22`；交互安装时可选择改为自定义端口。

## 核心组件

| 组件 | 协议/端口 | 作用 |
|------|-----------|------|
| dnsdist | TCP 853 | Android Private DNS / DoT TLS 前端 |
| mosdns | TCP/UDP 53, TCP/UDP 127.0.0.1:5353/5354 | 智能 DNS 分流策略 |
| sniproxy | TCP 80/443 | 默认 direct 模式 HTTP/HTTPS SNI/Host 透明反代 |
| 5gpn-tcp-proxy | TCP 80/443 | 可选 SOCKS5 出口模式 HTTP/HTTPS SNI/Host 透明反代 |
| quic-proxy | UDP 443 | QUIC/HTTP3 SNI 透明反代 |
| china-dns-race-proxy | TCP/UDP 127.0.0.1:5301 | 国内 DNS 并发竞速、TCP 重试、海外 fallback |
| Certbot | - | Let's Encrypt 证书申请与续期 |

## 访问策略

- DNS 53：仅允许 `172.22.0.0/16` 来源访问。
- DoT 853：允许所有来源访问，但只有 `172.22.0.0/16` 会获得代理劫持结果。
- TCP 80/443：仅允许 `172.22.0.0/16` 访问 sniproxy。
- UDP 443：仅允许 `172.22.0.0/16` 访问 quic-proxy。
- SSH：默认端口 `22`，交互安装时可选择修改。

| 来源 IP | proxy/GFWList 域名 | china/ChinaList 域名 | direct/默认域名 |
|---------|--------------------|----------------------|-----------------|
| `172.22.0.0/16` | 返回 VPS IP，进入 TCP/QUIC 反代 | 走本机 China DNS 竞速代理 | A 记录默认返回 VPS IP，进入 TCP/QUIC 反代 |
| 其他来源 | 不返回 VPS IP，正常解析 | 走本机 China DNS 竞速代理 | 走公网海外 DNS 池 |

DNS 服务默认不返回 AAAA 记录，客户端只使用 IPv4。

## 快速开始

### 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

没有 `curl` 时：

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

### 手动安装

```bash
chmod +x install.sh
./install.sh
```

安装过程会完成：依赖安装、自有域名校验、Let's Encrypt 证书申请、dnsdist/mosdns/sniproxy/quic-proxy/china-dns-race-proxy 安装、规则初始化、nftables 防火墙、系统网络优化、定时续期和规则更新。

## 域名准备

准备一个你自己的域名，并将 A 记录解析到 VPS 公网 IPv4：

```text
dot.example.com  A  <VPS 公网 IPv4>
```

非交互部署示例：

```bash
export DOMAIN="dot.example.com"
export EMAIL="admin@example.com"
./install.sh
```

如果解析尚未完全生效，或使用特殊 DNS 环境：

```bash
export DOMAIN="dot.example.com"
export SKIP_DNS_CHECK=1
./install.sh
```

## DNS 上游配置

```bash
export PRIVATE_OVERSEAS_DNS="22.22.22.22"
export PUBLIC_OVERSEAS_DNS="1.1.1.1,8.8.8.8"
export SNIPROXY_DNS="22.22.22.22"
export NPN_CLIENT_CIDRS="172.22.0.0/16"
./install.sh
```

- `NPN_CLIENT_CIDRS`：会被 mosdns 识别为专网客户端的 DNS 来源 CIDR，默认 `172.22.0.0/16`；如果 DoT 查询实际来自其它专网/NAT 段，可以追加，例如 `172.22.0.0/16,100.64.0.0/10`。
- `PRIVATE_OVERSEAS_DNS`：`172.22.0.0/16` 专网客户端默认海外解析。
- `PUBLIC_OVERSEAS_DNS`：非专网 DoT 客户端默认海外解析。
- `SNIPROXY_DNS`：sniproxy 后端解析 resolver，默认跟随 `PRIVATE_OVERSEAS_DNS`。
- `EGRESS_MODE`：proxy 出口模式，`direct` 使用 sniproxy/quic-proxy 直连，`socks5` 使用 5gpn-tcp-proxy/quic-proxy 走 SOCKS5。
- `EGRESS_SOCKS5_ADDR`：`EGRESS_MODE=socks5` 时的本机 SOCKS5 出口，默认 `127.0.0.1:1080`。
- `OVERSEAS_DNS`：兼容旧参数，等同于 `PRIVATE_OVERSEAS_DNS`。

配置会保存到 `/etc/mosdns/.overseas_private_dns`、`/etc/mosdns/.overseas_public_dns`、`/etc/mosdns/.sniproxy_dns`。

## 自定义分流规则与订阅

本地规则：

| 类型 | 文件 | 行为 |
|------|------|------|
| proxy | `/etc/mosdns/rules/custom/proxy.txt` | 专网客户端返回 VPS IP，进入 sniproxy/quic-proxy |
| direct | `/etc/mosdns/rules/custom/direct.txt` | 强制走海外 DNS 正常解析 |
| china | `/etc/mosdns/rules/custom/china.txt` | 强制走本机 China DNS 竞速代理 |
| reject | `/etc/mosdns/rules/custom/reject.txt` | 拒绝解析 |

订阅 URL：

| 类型 | 文件 |
|------|------|
| proxy | `/etc/mosdns/subscriptions/proxy-urls.txt` |
| direct | `/etc/mosdns/subscriptions/direct-urls.txt` |
| china | `/etc/mosdns/subscriptions/china-urls.txt` |
| reject | `/etc/mosdns/subscriptions/reject-urls.txt` |

每行一个订阅 URL，URL 内容支持纯域名列表、Adblock `||example.com^`、Clash/Surge/Quantumult `DOMAIN,example.com,Proxy` / `DOMAIN-SUFFIX,example.com,Proxy` / `DOMAIN-KEYWORD,example.com,Proxy`，以及 dnsmasq `server=/example.com/114.114.114.114` / `address=/example.com/1.2.3.4` / `ipset=/example.com/tag` 格式。执行后会规范化域名并合并去重：

```bash
./install.sh --update-rules
```

## 管理命令

```bash
./install.sh --status          # 查看运行状态
./install.sh --update-rules    # 更新 GFWList/ChinaList/自定义订阅
./install.sh --renew-cert      # 续期证书并重启 mosdns
./install.sh --uninstall       # 卸载组件与配置
```

## DNS Query Diagnostics

Per-query DNS logs are disabled by default to avoid noisy journals. Enable them only while troubleshooting split routing:

```bash
echo 1 > /etc/mosdns/.query_log
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
journalctl -u mosdns -f
```

`5gpn-private` means the 5G private-network/local diagnostic entry. `5gpn-public` means the public DoT entry. The mosdns summary includes the query name, type, and response records. Disable it after debugging:

如果国外域名故障时日志显示 `5gpn-public`，说明该 DNS 查询没有命中 `NPN_CLIENT_CIDRS`，mosdns 会返回真实公网解析而不是 VPS IP，VPS 443 就不会收到连接。此时先抓 DNS 来源地址，再把对应 CIDR 写入：

```bash
tcpdump -ni any 'port 53 or port 853'
echo '172.22.0.0/16,100.64.0.0/10' > /etc/mosdns/.npn_client_cidrs
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
```

```bash
echo 0 > /etc/mosdns/.query_log
RULE_DOWNLOAD_TOOL=wget /usr/local/bin/update-mosdns-rules.sh
```

## SOCKS5 Egress

交互安装时脚本会询问 proxy 出站模式：

- `direct`：当前 VPS 直接连接目标站点，TCP 使用 sniproxy，UDP/443 使用 quic-proxy。
- `socks5`：当前 VPS 把 TCP 80/443 和 UDP/443 QUIC 流量交给本机 SOCKS5 出口，按提示填写 `ip:port`，例如 `127.0.0.1:1080`。

默认 TCP 80/443 使用 `sniproxy` 从当前 VPS 直接出站。若你在 VPS 本机部署了 Xray/sing-box 并开放 SOCKS5，例如 `127.0.0.1:1080`，可以让 proxy 域名的 TCP 流量经该 SOCKS5 出口：

```bash
export EGRESS_MODE=socks5
export EGRESS_SOCKS5_ADDR="127.0.0.1:1080"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/panghuchi/5GPN/main/install.sh)"
```

如果选择由安装脚本同时安装 Xray，脚本会使用官方安装器安装 Xray，并写入 `/usr/local/etc/xray/config.json`。Xray inbound 会监听前面填写的 SOCKS5 地址，outbound 会按交互输入的 SS2022 参数生成：

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

### SS2022 出口管理

安装后可以保存多个 SS2022 出口，并按需切换。出口库存保存在 `/opt/proxy-gateway/etc/exits/*.json`，当前出口保存在 `/opt/proxy-gateway/etc/.current_exit`；Xray 配置文件只渲染当前选中的一个出口，不保存完整出口列表。

```bash
./install.sh --add-exit
./install.sh --list-exits
./install.sh --set-exit hk
```

`--add-exit` 默认交互输入出口名、服务器地址、端口、加密方法和密码；非交互时也可以传入 `NAME ADDRESS PORT METHOD PASSWORD` 五个参数。

`--set-exit` 会把 proxy 出口切到本机 Xray SOCKS5，重写当前出口对应的 `/usr/local/etc/xray/config.json`，并重启 Xray、`5gpn-tcp-proxy` 和 `quic-proxy`。

也可以安装后修改：

```bash
cat > /opt/proxy-gateway/etc/egress.env <<'EOF'
EGRESS_MODE=socks5
EGRESS_SOCKS5_ADDR=127.0.0.1:1080
EGRESS_SOCKS5_USERNAME=
EGRESS_SOCKS5_PASSWORD=
EOF
systemctl restart 5gpn-tcp-proxy
systemctl stop sniproxy
```

SOCKS5 egress 会同时覆盖 TCP 80/443 和 UDP/443 QUIC。Xray/sing-box 的 SOCKS5 入站需要开启 UDP 支持，否则 QUIC 会失败或回退到 TCP。

## 关键文件

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本 |
| `mosdns_config.yaml` | mosdns 配置模板 |
| `update-rules.sh` | 规则更新与订阅合并脚本 |
| `renew-hook.sh` | 证书续期 Hook |
| `sniproxy.conf` | sniproxy 配置模板 |
| `5gpn-tcp-proxy.go` | 支持 direct/SOCKS5 出口的 TCP Host/SNI 代理源码 |
| `quic-proxy.go` | QUIC SNI 代理源码 |
| `china-dns-race-proxy.go` | 国内 DNS 竞速代理源码 |

## 技术说明

### mosdns 分流

dnsdist 监听公网 TCP 853 并终止 DoT/TLS，然后按来源 CIDR 转发到 mosdns 的本地 private/public 后端。mosdns 使用不同入口区分普通 DNS 与 DoT 前端流量：普通 DNS 53 对非专网来源拒绝，dnsdist 的 DoT 853 对公网开放但不向公网来源返回代理 IP。专网客户端中，china/ChinaList 真实解析，direct 为人工真实解析例外，其余 A 记录默认返回 VPS IP。

### 国内解析

ChinaList 和自定义 china 域名会转发到 `127.0.0.1:5301`。`china-dns-race-proxy` 默认使用 `223.5.5.5`、`223.6.6.6` 并发查询，`150ms` 后启动国内 TCP 53 重试，`750ms` 后才启用海外 fallback，避免国内 DNS 单点超时拖慢访问。国内查询默认注入 EDNS Client Subnet `139.226.48.0/24`，用于让国内 CDN 返回更接近中国网络的地址；可在 `/opt/proxy-gateway/etc/china-dns-race-proxy.env` 中覆盖：

```bash
CHINA_DNS_UPSTREAMS=223.5.5.5:53,223.6.6.6:53
CHINA_DNS_ECS=139.226.48.0/24
```

### TCP 代理

sniproxy 从源码编译安装到 `/usr/local/sbin/sniproxy`，避免发行版包路径和编译选项差异导致启动失败。安装脚本会生成 `/etc/sniproxy.conf`，并写入 `SNIPROXY_DNS` 对应 resolver，同时强制 `mode ipv4_only`。它不解密 TLS，只按 SNI/Host 转发。

### QUIC/HTTP3 代理

`quic-proxy` 监听 UDP 443，解析 QUIC v1 Initial 包中的 TLS ClientHello SNI，然后转发到真实后端。若客户端使用不兼容的 QUIC 版本，通常会回退 TCP/HTTP2。

### 防火墙

脚本生成 `/etc/nftables.conf`，使用 `table ip nat` 和 `table ip filter`。反代端口保留固定专网限制格式：

```nft
ip saddr 172.22.0.0/16 tcp dport { 80, 443 } accept
ip saddr 172.22.0.0/16 udp dport 443 accept
```

## 故障排查

```bash
# 服务状态
systemctl status dnsdist
systemctl status mosdns
systemctl status sniproxy
systemctl status quic-proxy
systemctl status china-dns-race-proxy

# 实时日志
journalctl -u dnsdist -f
journalctl -u mosdns -f
journalctl -u sniproxy -f
journalctl -u quic-proxy -f
journalctl -u china-dns-race-proxy -f

# 测试 DoT
dig +tls @dot.example.com -p 853 youtube.com

# 测试 TCP 反代
curl -I --resolve youtube.com:443:<VPS_IP> https://youtube.com
```

## 安全说明

本项目用于企业合法跨境业务互通。专用域名和专网端口限制可以降低误暴露风险，但不能完全消除服务器 IP 被主动探测、封禁或滥用的可能。
