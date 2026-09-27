# NanoPi R3S 旁路由模式

基于 Debian / Ubuntu，以下命令以 root 执行。R3S 只运行 Mihomo，拨号和 DHCP 继续交给主路由。

## 网络约定

| 项目 | 示例值 |
| --- | --- |
| 主路由 | `192.168.5.1` |
| R3S | `192.168.5.2/24`，`eth0` 接主路由 LAN，另一个网口留空 |
| R3S 默认网关 | `192.168.5.1` |
| 需要代理的客户端 | IPv4 网关和 DNS 都设为 `192.168.5.2` |

`192.168.5.2` 为 R3S 的固定地址，需要在主路由 DHCP 地址池中排除或绑定保留，避免地址冲突。网口名称和网段以实际环境为准，`ip -br link` 可查看网口名称。

**客户端会通过 IPv6 绕过旁路由，所以需要关闭主路由和 R3S 的 IPv6。** 手动设置的 IPv4 网关只对 IPv4 流量生效，客户端的 IPv6 流量仍会直接走主路由，不经过 R3S 上的 Mihomo。仅将 Mihomo 的 `ipv6` 设为 `false` 不会关闭客户端的 IPv6，也无法阻止这种绕行。

## 网络接口

通过本地控制台修改网络，下面使用 ifupdown 管理 `eth0`。如果镜像使用 Netplan 或 systemd-networkd，应在现有管理工具中设置同样的静态地址、网关和 DNS，不要让多个服务同时管理网口。

```bash
apt update
apt install -y ifupdown curl ca-certificates jq gzip unzip dnsutils nftables

cp -a /etc/network/interfaces /tmp/interfaces.bak
cat <<'EOF' >/etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.5.2/24
    gateway 192.168.5.1
EOF

# 若原先由 NetworkManager 管理，先停用它
systemctl disable --now NetworkManager
systemctl restart networking
```

R3S 本机保留公共 DNS 用于下载程序和订阅，默认网关指向主路由，不能填自己。手动管理 `/etc/resolv.conf` 时：

```bash
cp -a /etc/resolv.conf /tmp/resolv.conf.bak
# 若此前锁定过，先执行 chattr -i /etc/resolv.conf
rm -f /etc/resolv.conf
cat <<'EOF' >/etc/resolv.conf
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF
chattr +i /etc/resolv.conf
```

若由 resolvconf 或 systemd-resolved 管理 DNS，则在对应服务中设置上述公共 DNS，不执行这段覆盖和锁定命令。

## sysctl

开启 IPv4 转发，关闭 ICMP Redirect，避免同网口转发时提示客户端改走主路由；同时关闭反向路径过滤和 IPv6。

```bash
cat <<'EOF' >/etc/sysctl.d/99-side-router.conf
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.eth0.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.eth0.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl --system
```

## Mihomo

[中文文档](https://wiki.metacubex.one/) · [官方配置示例](https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml) · [TUN](https://wiki.metacubex.one/config/inbound/tun/) · [DNS](https://wiki.metacubex.one/config/dns/)

```bash
VER=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -er .tag_name)
curl -fL "https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-arm64-${VER}.gz" -o /tmp/mihomo.gz
gzip -dc /tmp/mihomo.gz > /tmp/mihomo
install -m 755 /tmp/mihomo /usr/bin/mihomo
mihomo -v

mkdir -p /etc/mihomo
curl -fL https://raw.githubusercontent.com/MetaCubeX/mihomo/Meta/.github/release/mihomo.service -o /etc/systemd/system/mihomo.service

curl -fL https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip -o /tmp/zashboard.zip
mkdir -p /etc/mihomo/ui/zashboard
unzip -o /tmp/zashboard.zip -d /etc/mihomo/ui/zashboard
```

配置中的订阅链接、面板密码 `<PASSWORD>`，以及 WireGuard 的服务器地址 `<IP>`、端口 `<PORT>`、公钥 `<PUBLICK-KEY>` 和私钥 `<PRIVATE-KEY>` 均需替换为实际值。面板密码可用 `openssl rand -hex 24` 生成。

DNS 监听 `192.168.5.2:1053`，客户端发往 `53` 端口的查询由 TUN 的 `dns-hijack` 接管。验证时分别检查 `1053` 监听和客户端的 `53` 端口查询。

```bash
[ ! -f /etc/mihomo/config.yaml ] || cp -a /etc/mihomo/config.yaml /tmp/mihomo-config.yaml.bak
cat <<'EOF' >/etc/mihomo/config.yaml
# https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml
mixed-port: 7890
allow-lan: true
bind-address: 192.168.5.2
lan-allowed-ips:
  - 192.168.5.0/24
ipv6: false
unified-delay: true
tcp-concurrent: true
log-level: warning
find-process-mode: off
keep-alive-idle: 600
keep-alive-interval: 15
disable-keep-alive: false
profile:
  store-selected: true
  store-fake-ip: true

external-controller: 192.168.5.2:9090
secret: "<PASSWORD>"
external-ui: "/etc/mihomo/ui"
external-ui-name: zashboard
external-ui-url: "https://cdn.gh-proxy.org/github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"

tun:
  enable: true
  stack: mixed
  dns-hijack: ["any:53", "tcp://any:53"]
  device: mihomo
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  mtu: 1492
  exclude-uid:
    - 999

dns:
  enable: true
  prefer-h3: false
  cache-algorithm: arc
  enhanced-mode: fake-ip
  listen: 192.168.5.2:1053
  ipv6: false
  respect-rules: true
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - "rule-set:private-domain"
    - "rule-set:ntp-domain"
    - "rule-set:connectivity-domain"
  default-nameserver:
    - 223.5.5.5
    - 1.12.12.12
    - 180.184.1.1
  nameserver:
    - "https://1.1.1.1/dns-query#🔄 Fallback"
    - "https://8.8.8.8/dns-query#🔄 Fallback"
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  nameserver-policy:
    "+.ping0.cc":
      - rcode://success
    "rule-set:cn-domain,kaspersky-domain,private-domain,ntp-domain,connectivity-domain":
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query

geo-auto-update: true
geo-update-interval: 72
geox-url:
  geoip: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geoip.dat
  geosite: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
  mmdb: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb
  asn: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb

proxy-providers:
  Airport1:
    url: "<PROVIDER-URL>"
    type: http
    interval: 86400
    health-check:
      enable: true
      url: https://connectivitycheck.gstatic.com/generate_204
      interval: 300
    proxy: DIRECT

proxies:
  - name: wg-cloud
    type: wireguard
    server: <IP>
    port: <PORT>
    ip: 10.8.0.3/32
    mtu: 1400
    public-key: <PUBLICK-KEY>
    private-key: <PRIVATE-KEY>
    udp: true

anchor:
  rule-ip: &rule-ip {type: http, interval: 86400, behavior: ipcidr, format: mrs}
  rule-domain: &rule-domain {type: http, interval: 86400, behavior: domain, format: mrs}
  airport-select: &airport-select {type: select, use: [Airport1], proxies: [🔄 Fallback, DIRECT]}

proxy-groups:
  - { name: 🔄 Fallback, type: fallback, use: [Airport1] }
  - { name: 🚀 代理, <<: *airport-select }
  - { name: 🐳 Docker, <<: *airport-select }
  - { name: 🔎 Google, <<: *airport-select }
  - { name: 🪟 Microsoft, <<: *airport-select }
  - { name: ♾️ Meta, <<: *airport-select }
  - { name: 🐱 CodeRepo, <<: *airport-select }
  - { name: 🤖 AI, <<: *airport-select }
  - { name: 🛩️ Telegram, <<: *airport-select }
  - { name: 👽 Reddit, <<: *airport-select }
  - { name: 🎥 NETFLIX, <<: *airport-select }
  - { name: 📡 Speedtest, <<: *airport-select }
  - { name: 🎮 Games, <<: *airport-select }
  - { name: 🍎 Apple, <<: *airport-select }
  - { name: 🐔 NodeSeek, <<: *airport-select }
  - { name: 🎧 Spotify, <<: *airport-select }
  - { name: 💬 LINE, <<: *airport-select }
  - { name: 🐟 漏网之鱼, <<: *airport-select }

rules:
  - RULE-SET,icloudprivaterelay-domain,REJECT
  - RULE-SET,httpdns-cn-domain,REJECT
  - RULE-SET,win-spy-domain,REJECT
  - DOMAIN-SUFFIX,ping0.cc,REJECT

  - IP-CIDR,10.46.96.0/22,wg-cloud,no-resolve
  - IP-CIDR,10.8.0.0/24,wg-cloud,no-resolve

  - RULE-SET,private-domain,DIRECT
  - RULE-SET,private-ip,DIRECT,no-resolve
  - RULE-SET,ntp-domain,DIRECT
  - RULE-SET,connectivity-domain,DIRECT

  - RULE-SET,kaspersky-domain,DIRECT
  - RULE-SET,apple-cn-domain,DIRECT
  - RULE-SET,apple-domain,🍎 Apple
  - RULE-SET,nodeseek-domain,🐔 NodeSeek
  - RULE-SET,google-domain,🔎 Google
  - RULE-SET,gitlab-domain,🐱 CodeRepo
  - RULE-SET,github-domain,🐱 CodeRepo
  - RULE-SET,microsoft-cn-domain,🪟 Microsoft
  - RULE-SET,microsoft-domain,🪟 Microsoft
  - RULE-SET,meta-domain,♾️ Meta
  - RULE-SET,ai-domain,🤖 AI
  - RULE-SET,docker-domain,🐳 Docker
  - RULE-SET,speedtest-domain,📡 Speedtest
  - RULE-SET,telegram-domain,🛩️ Telegram
  - RULE-SET,steam-domain,🎮 Games
  - RULE-SET,epicgames-domain,🎮 Games
  - RULE-SET,reddit-domain,👽 Reddit
  - RULE-SET,netflix-domain,🎥 NETFLIX
  - RULE-SET,spotify-domain,🎧 Spotify
  - RULE-SET,line-domain,💬 LINE
  - RULE-SET,adobe-domain,🚀 代理

  - RULE-SET,apple-ip,🍎 Apple,no-resolve
  - RULE-SET,google-ip,🔎 Google,no-resolve
  - RULE-SET,telegram-ip,🛩️ Telegram,no-resolve
  - RULE-SET,netflix-ip,🎥 NETFLIX,no-resolve

  - RULE-SET,cn-domain,DIRECT
  - RULE-SET,gfw-domain,🚀 代理
  - RULE-SET,geolocation-!cn,🚀 代理
  - RULE-SET,cn-ip,DIRECT

  - MATCH,🐟 漏网之鱼

rule-providers:
  icloudprivaterelay-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/icloudprivaterelay.mrs" }
  httpdns-cn-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-httpdns-cn.mrs" }
  win-spy-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/win-spy.mrs" }

  private-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/private.mrs" }
  private-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/private.mrs" }
  ntp-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ntp.mrs" }
  connectivity-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/zzwsec/mihomo-rules@main/connectivity-domain.mrs" }

  kaspersky-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/kaspersky.mrs" }
  apple-cn-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/apple-cn.mrs" }
  apple-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/apple.mrs" }
  nodeseek-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/nodeseek.mrs" }
  google-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/google.mrs" }
  gitlab-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/gitlab.mrs" }
  github-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/github.mrs" }
  microsoft-cn-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/microsoft@cn.mrs" }
  microsoft-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/microsoft.mrs" }
  meta-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/meta.mrs" }
  ai-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ai-!cn.mrs" }
  docker-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/docker.mrs" }
  speedtest-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/ookla-speedtest.mrs" }
  telegram-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/telegram.mrs" }
  steam-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/steam.mrs" }
  epicgames-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/epicgames.mrs" }
  reddit-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/reddit.mrs" }
  netflix-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/netflix.mrs" }
  spotify-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/spotify.mrs" }
  line-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/line.mrs" }
  adobe-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/adobe.mrs" }

  apple-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo-lite/geoip/apple.mrs" }
  google-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/google.mrs" }
  telegram-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/telegram.mrs" }
  netflix-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/netflix.mrs" }

  cn-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs" }
  gfw-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/gfw.mrs" }
  geolocation-!cn: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/geolocation-!cn.mrs" }
  cn-ip: { <<: *rule-ip, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.mrs" }
EOF

mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml
```

检查通过后启动。订阅和规则文件首次下载也需要网络可达，启动日志中不能有持续下载失败。

```bash
systemctl daemon-reload
systemctl enable mihomo
systemctl restart mihomo
systemctl status mihomo --no-pager -l
journalctl -u mihomo -n 50 --no-pager
```

打开 `http://192.168.5.2:9090/ui/zashboard/`，填写面板密钥，选择对应节点。Mihomo 通过 `auto-route` 和 `auto-redirect` 自动配置路由与流量重定向。若系统启用了防火墙，需要放行局域网客户端的 DNS 请求（TCP/UDP 53）、面板访问（TCP 9090）以及进入 TUN 的流量。调整防火墙时，注意避免误删 Mihomo 自动生成的 nftables 规则。

## 客户端

只修改需要代理的设备，主路由的 DHCP 默认网关和 DNS 保持原样。

| 设置 | 示例值 |
| --- | --- |
| IPv4 地址 | `192.168.5.100`，在主路由中预留，避免地址冲突 |
| 子网掩码 / 前缀长度 | `255.255.255.0` / `24` |
| 默认网关 | `192.168.5.2` |
| DNS | `192.168.5.2` |
| 备用 DNS | 留空，不填主路由或公共 DNS |
| IPv6 | 在主路由关闭 IPv6 |

Windows 在网卡 IPv4 属性中填写地址、网关和 DNS；手机等设备在当前网络的手动 IP 设置中填写。IPv6 在主路由统一关闭。

关闭客户端的私人 DNS、浏览器自定义 DoH 等独立解析设置，让 DNS 查询进入 Mihomo。普通 DNS 的劫持不能替代对加密 DNS 的设置。

## 验证

先在 R3S 上确认 Mihomo 的 DNS 可用：

```bash
dig @192.168.5.2 -p 1053 example.com A +short
dig +tcp @192.168.5.2 -p 1053 example.com A +short
dig @192.168.5.2 -p 1053 example.com AAAA +short
```

前两项应返回 `198.18.0.0/16` 内的 Fake-IP，最后一项不应返回 AAAA 地址。

再从客户端验证，不能只在 R3S 本机测试：

```bash
nslookup example.com 192.168.5.2
curl -4 -I https://www.google.com
```

退出旁路由时，将客户端网关和 DNS 恢复为主路由地址，或恢复自动获取，随后清理 DNS 缓存 / 重连网络。R3S 停机不会自动把已指定它的客户端切回主路由。
