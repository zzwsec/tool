# NanoPi R3S 主路由模式

基于 Debian / Ubuntu 系统，使用 PPPoE、dnsmasq、SmartDNS 与 Mihomo。以下命令以 root 执行；网口名称先用 `ip -br link` 核对，修改网络配置时建议通过本地控制台操作。

## 网络约定

| 项目 | 示例值 |
| --- | --- |
| WAN / PPPoE | `eth0` / `ppp0` |
| LAN | `eth1`，`192.168.5.1/24` |
| LAN IPv6 ULA | `fd00:1234:5678:5::1/64`，部署时换成自建前缀 |
| dnsmasq | 本机与 LAN 的 `53` 端口 |
| SmartDNS | `127.0.0.1:6053` |
| Mihomo DNS | `127.0.0.1:1053` |

先完成 `dnsmasq → SmartDNS → 公共 DoH`，确认能解析后再启用 Mihomo，最后将 dnsmasq 上游切到 `1053`。SmartDNS 的启动解析使用阿里云 `223.5.5.5` 与腾讯 `119.29.29.29` 的 UDP DNS；正式上游使用两家的公共 DoH。Mihomo 原有的代理域名解析路径仍走 Cloudflare / Google，并通过代理组出站。

## 前置准备

1. 下载固件

[NanoPi R3S 固件下载](https://dl.friendlyelec.com/nanopir3s)。本文针对 Debian / Ubuntu 镜像；默认账号以所选镜像说明为准。

2. 加载 `nf_conntrack` 连接跟踪模块

```bash
modprobe nf_conntrack
echo "nf_conntrack" >> /etc/modules-load.d/r3s.conf
```

3. 时区

```bash
timedatectl set-timezone Asia/Shanghai
```

4. 修改密码

```bash
passwd root
```

5. 删除默认 pi 用户

先确认已能使用其他管理员账号或 root 登录，再删除默认用户。

```bash
deluser --remove-home pi
```

6. 时间同步

```bash
apt update
apt install -y chrony
mkdir -p /etc/chrony/sources.d
cp -a /etc/chrony/chrony.conf /tmp/chrony.conf.bak
sed -i 's#^pool#\# pool#' /etc/chrony/chrony.conf

cat <<EOF >/etc/chrony/sources.d/r3s.sources
server ntp.aliyun.com iburst
server ntp.tencent.com iburst
pool ntp.ntsc.ac.cn iburst
EOF

systemctl restart chrony
systemctl status chrony --no-pager -l

chronyc sources -v
```

## 网络接口

初始化阶段先使用阿里云和腾讯公共 DNS；后面 dnsmasq 验证通过后，再切换到 `127.0.0.1`。

```bash
apt update
apt install -y ifupdown
cat <<\EOF >/etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug eth1
iface eth1 inet static
address 192.168.5.1
netmask 255.255.255.0
EOF

systemctl disable --now NetworkManager
systemctl restart networking

# 改为手动维护系统 DNS，避免继续指向 NetworkManager 的解析文件
cp -a /etc/resolv.conf /tmp/resolv.conf.before-router
rm -f /etc/resolv.conf
cat <<'EOF' >/etc/resolv.conf
nameserver 223.5.5.5
nameserver 119.29.29.29
EOF

apt purge network-manager -y
apt autoremove --purge -y
rm -rf /etc/NetworkManager
```

```bash
apt update
apt install -y curl wget ca-certificates nftables chrony bash-completion jq file tree fastfetch unzip zstd tar bridge-utils nmap iperf3 iftop tmux dnsutils sysstat
apt install -y ppp pppoe ifupdown smartdns dnsutils dnsmasq
```

## PPPoE

```bash
apt install -y ppp pppoe ifupdown

cat >/etc/ppp/peers/dsl-provider <<'EOF'
plugin rp-pppoe.so eth0

noauth
hide-password

defaultroute
replacedefaultroute

persist
maxfail 0
holdoff 5

mtu 1492
mru 1492

+ipv6

user "<PPPOE_USERNAME>"

# DNS 由本地 dnsmasq 管理，不使用 usepeerdns 覆盖 resolv.conf
EOF

cat >> /etc/ppp/chap-secrets <<'EOF'
"<PPPOE_USERNAME>" * "<PPPOE_PASSWORD>"
EOF

cat >> /etc/ppp/pap-secrets <<'EOF'
"<PPPOE_USERNAME>" * "<PPPOE_PASSWORD>"
EOF

chmod 600 /etc/ppp/chap-secrets /etc/ppp/pap-secrets
```

```bash
pon dsl-provider
journalctl --since '5 min ago' --no-pager -l
ip addr show ppp0
ip route
ip -6 addr show dev ppp0
ip -6 route show default
```

```bash
cp -a /etc/network/interfaces /tmp/interfaces.bak

cat <<'EOF' >/etc/network/interfaces
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual

auto eth1
iface eth1 inet static
    address 192.168.5.1
    netmask 255.255.255.0

iface eth1 inet6 static
    address fd00:1234:5678:5::1/64

auto dsl-provider
iface dsl-provider inet ppp
    pre-up /bin/ip link set eth0 up
    provider dsl-provider
EOF

systemctl restart networking
```

🎊 因为 `eth1 = LAN`、`ppp0 = WAN` ，所以这里 不写 `IPv6 gateway`，默认 IPv6 路由还是 `ppp0` 从运营商 RA 学到的。

## SmartDNS

[中文官网](https://pymumu.github.io/smartdns/) · [官方配置示例](https://github.com/pymumu/smartdns/blob/master/etc/smartdns/smartdns.conf)

`server` 使用 UDP；带 `-bootstrap-dns -exclude-default-group` 的两个地址只解析 DoH 服务器域名。正常查询走公共 `dns.alidns.com` 和 `doh.pub`。

```bash
apt install -y smartdns dnsutils ca-certificates
systemctl stop smartdns

id smartdns 2>/dev/null || useradd -M -r -s /usr/sbin/nologin smartdns
id -u smartdns # 记录实际 UID，mihomo 配置需要

cp -a /etc/smartdns/smartdns.conf /tmp/smartdns.conf.bak
cat <<'EOF' >/etc/smartdns/smartdns.conf
bind 127.0.0.1:6053
bind-tcp 127.0.0.1:6053

# Bootstrap
server 223.5.5.5 -bootstrap-dns -exclude-default-group
server 119.29.29.29 -bootstrap-dns -exclude-default-group

# 正式上游
server-https https://dns.alidns.com/dns-query
server-https https://doh.pub/dns-query

speed-check-mode tcp:443,ping,tcp:80
response-mode fastest-ip

dualstack-ip-selection no

cache-size 20480
cache-persist yes
cache-file /var/cache/smartdns/smartdns.cache
cache-checkpoint-time 3600

prefetch-domain yes
serve-expired no

rr-ttl-min 300
rr-ttl-max 1800

log-level warn
audit-enable no
EOF

cat <<'EOF' >/etc/systemd/system/smartdns.service
[Unit]
Description=SmartDNS Server
After=network.target
Wants=nss-lookup.target
Before=nss-lookup.target

StartLimitBurst=0
StartLimitIntervalSec=60

[Service]
Type=forking

User=smartdns
Group=smartdns

EnvironmentFile=-/etc/default/smartdns

RuntimeDirectory=smartdns
RuntimeDirectoryMode=0755
PIDFile=/run/smartdns/smartdns.pid

CacheDirectory=smartdns
CacheDirectoryMode=0750

ExecStart=/usr/sbin/smartdns -p /run/smartdns/smartdns.pid $SMART_DNS_OPTS

Restart=always
RestartSec=2
TimeoutStopSec=15

CapabilityBoundingSet=CAP_NET_RAW
AmbientCapabilities=CAP_NET_RAW

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF


systemctl daemon-reload
systemctl restart smartdns
systemctl status smartdns --no-pager -l
systemctl show smartdns -p FragmentPath

ps -o user,uid,pid,cmd -C smartdns
ss -tunlp 'sport = 6053'
```

## dnsmasq

```bash
apt install dnsmasq -y

[ ! -f /etc/dnsmasq.d/lan.conf ] || cp -a /etc/dnsmasq.d/lan.conf /tmp/lan.conf.bak
cat <<'EOF' >/etc/dnsmasq.d/lan.conf
interface=eth1
bind-interfaces
listen-address=127.0.0.1,192.168.5.1,fd00:1234:5678:5::1

# DHCPv4
dhcp-range=192.168.5.10,192.168.5.200,12h

# IPv4 gateway
dhcp-option=3,192.168.5.1

# IPv4 DNS
dhcp-option=6,192.168.5.1

# IPv6 RA + SLAAC
enable-ra
dhcp-range=::,constructor:eth1,ra-stateless,64,12h

# IPv6 DNS / RDNSS
dhcp-option=option6:dns-server,[fd00:1234:5678:5::1]

# DNS -> SmartDNS
no-resolv
server=127.0.0.1#6053

# 静态租约示例（按需取消注释并替换为自己的设备信息）
# dhcp-host=02:00:00:00:00:02,192.168.5.2,lan-device,infinite
EOF
```

```bash
dnsmasq --test
systemctl restart dnsmasq
systemctl status dnsmasq --no-pager -l
ss -lntup 'sport = :53'
```

若 `/etc/resolv.conf` 为手动维护的普通文件，写入本机 DNS 并锁定，避免被覆盖：

```bash
cp -a /etc/resolv.conf /tmp/resolv.conf.bak
cat <<'EOF' >/etc/resolv.conf
nameserver 127.0.0.1
EOF

chattr +i /etc/resolv.conf
```

后续修改前先执行 `chattr -i /etc/resolv.conf` 解锁。若由 resolvconf、systemd-resolved 或 NetworkManager 管理，则在对应服务配置中将 DNS 设为 `127.0.0.1`，不要直接覆盖或锁定该文件。

## Mihomo

配置写入后，先替换 `<MIHOMO_API_SECRET>`、`<SMARTDNS_UID>` 和订阅示例地址，再启动服务。可用 `openssl rand -hex 24` 生成面板密钥；UID 必须是 `id -u smartdns` 返回的数字，不能照抄其他设备的值。SmartDNS 的出站流量需要排除在 TUN 接管之外，以免 DNS 回环。

```bash
PROXY_GITHUB="" # 默认直接访问 GitHub；按需填写可信下载代理前缀
VER=$(curl -fsSL https://${PROXY_GITHUB:-}api.github.com/repos/MetaCubeX/mihomo/releases/latest | jq -r .tag_name)
curl -fSL "https://${PROXY_GITHUB:-}github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-arm64-${VER}.gz" | gzip -d > /usr/bin/mihomo
chmod +x /usr/bin/mihomo
mihomo -v
wget -O /usr/lib/systemd/system/mihomo.service https://${PROXY_GITHUB:-}raw.githubusercontent.com/MetaCubeX/mihomo/refs/heads/Meta/.github/release/mihomo.service
```

```bash
mkdir -p /etc/mihomo/ui
rm -rf /etc/mihomo/ui/zashboard
wget -O /tmp/zashboard.zip https://${PROXY_GITHUB:-}github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip
unzip /tmp/zashboard.zip -d /etc/mihomo/ui/
mv /etc/mihomo/ui/{zashboard-gh-pages,zashboard}
rm -rf /tmp/zashboard.zip
```

```bash
cat <<'EOF' > /etc/mihomo/config.yaml
# https://github.com/MetaCubeX/mihomo/blob/Meta/docs/config.yaml
mixed-port: 7890
allow-lan: true
bind-address: 192.168.5.1
lan-allowed-ips:
  - 192.168.5.0/24
ipv6: true
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

external-controller: 192.168.5.1:9090
secret: "<MIHOMO_API_SECRET>"
external-ui: "/etc/mihomo/ui"
external-ui-name: zashboard
external-ui-url: "https://cdn.gh-proxy.org/github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"

tun:
  enable: true
  stack: mixed
  dns-hijack: ["any:53", "tcp://any:53"]
  device: mihomo-tun
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true
  mtu: 1492
  exclude-uid:
    - <SMARTDNS_UID> # 替换为 id -u smartdns 的数字输出

dns:
  enable: true
  prefer-h3: false
  cache-algorithm: arc
  enhanced-mode: fake-ip
  listen: 127.0.0.1:1053
  ipv6: true
  fake-ip-range: 198.18.0.1/16
  # IPv6 Fake-IP 相关讨论：https://github.com/MetaCubeX/mihomo/issues/3064
  fake-ip-range6: 2001:2::/48
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - "rule-set:private-domain"
    - "rule-set:ntp-domain"
    - "rule-set:connectivity-domain"
    - "rule-set:stun-domain"
  default-nameserver:
    - "udp://127.0.0.1:6053"
  nameserver:
    - "https://1.1.1.1/dns-query#🔄 Fallback"
    - "https://8.8.8.8/dns-query#🔄 Fallback"
  proxy-server-nameserver:
    - "udp://127.0.0.1:6053"
  direct-nameserver:
    - "udp://127.0.0.1:6053"
  direct-nameserver-follow-policy: false
  nameserver-policy:
    "+.ping0.cc":
      - rcode://success
    "rule-set:private-domain,ntp-domain,connectivity-domain,stun-domain":
      - "udp://127.0.0.1:6053"

geo-auto-update: true
geo-update-interval: 72
geox-url:
  geoip: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geoip.dat
  geosite: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
  mmdb: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/geoip.metad
  asn: https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb

proxy-providers:
  Airport1:
    url: "https://example.com/your-subscription" # 替换为自己的订阅链接
    type: http
    interval: 86400
    client-fingerprint: firefox
    health-check:
      enable: true
      url: https://connectivitycheck.gstatic.com/generate_204
      interval: 300
    proxy: DIRECT

proxies: []

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
  - AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,geolocation-!cn)),REJECT


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
  stun-domain: { <<: *rule-domain, url: "https://cdn.jsdmirror.com/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-stun.mrs" }

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
```

```bash
systemctl daemon-reload
mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml
# 配置检查成功后再启动
systemctl enable --now mihomo.service
systemctl status mihomo.service --no-pager -l
```

打开 `http://192.168.5.1:9090/ui/zashboard/`，在面板连接设置中填写自己配置的密钥。

💡 在启用 mihomo 后，需要修改 dns 请求链路

```text
LAN / NanoPi 本机
        ↓
    dnsmasq :53
        ↓
    mihomo :1053
        ↓
     Fake-IP
        │
        ├─ 普通代理域名
        │    ↓
        │  1.1.1.1 / 8.8.8.8
        │
        └─ DIRECT / 节点域名
             ↓
       SmartDNS :6053
             ↓
        阿里云 / 腾讯公共 DoH
```

```bash
sed -i \
  -e 's|127\.0\.0\.1#6053|127.0.0.1#1053|' \
  -e 's|^# DNS -> SmartDNS$|# DNS -> mihomo|' \
  /etc/dnsmasq.d/lan.conf
dnsmasq --test
systemctl restart dnsmasq
```

先确认 SmartDNS 能返回真实地址，再检查 Mihomo 与 dnsmasq。普通域名的 A 记录应落在 `198.18.0.0/16`；匹配 fake-ip-filter 的域名会返回真实地址，不能要求所有查询都返回 Fake-IP。AAAA 结果还取决于当前 Mihomo 版本和 IPv6 配置。

```bash
runuser -u smartdns -- dig @127.0.0.1 -p 6053 example.com A +short
runuser -u smartdns -- dig @127.0.0.1 -p 1053 example.com A +short
runuser -u smartdns -- dig @127.0.0.1 -p 1053 example.com AAAA +short
runuser -u smartdns -- dig @127.0.0.1 example.com A +short
runuser -u smartdns -- dig @127.0.0.1 example.com AAAA +short
```

## nftables

```bash
cat <<'EOF' >/etc/nftables.conf
#!/usr/sbin/nft -f

table inet router_guard {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state invalid drop
        ct state established,related accept

        # Local
        iifname "lo" accept

        # Trusted LAN
        iifname "eth1" accept

        # mihomo TUN
        iifname "mihomo-tun" accept

        # ICMP / IPv6 ND、RA、PMTU
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept
    }
}
EOF

nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
nft list tables
systemctl enable nftables
```

 ⚠️ `nftables.service` 默认包含 `ExecStop=/usr/sbin/nft flush ruleset`，执行 `systemctl stop/restart nftables` 时会清空内核中的全部 nftables 规则，包括 mihomo 动态注入的规则。因此 mihomo 运行期间如需重新加载自定义防火墙规则，不要重启 `nftables.service`，应使用 `nft -f <rule-file-path>` 单独加载规则文件；同时规则文件中不要使用 `flush ruleset`，避免误删 mihomo 规则。

## sysctl

```bash
cat <<'EOF' >/etc/sysctl.d/99-router.conf
# Forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

-net.ipv6.conf.ppp0.accept_ra = 2

# TCP Queue
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096

net.core.rmem_default = 524288
net.core.wmem_default = 524288
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

net.ipv4.tcp_rmem = 8192 524288 33554432
net.ipv4.tcp_wmem = 8192 524288 33554432

net.ipv4.tcp_window_scaling = 1

# Conntrack
net.netfilter.nf_conntrack_max = 102400

net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60

# Neighbor Cache
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096

net.ipv6.neigh.default.gc_thresh1 = 512
net.ipv6.neigh.default.gc_thresh2 = 2048
net.ipv6.neigh.default.gc_thresh3 = 4096

# IPv4 Router Security
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# IPv6 Router Security
net.ipv6.icmp.echo_ignore_all = 0

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# mihomo TUN / policy routing
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv4.conf.eth1.rp_filter = 0
EOF

sysctl --system
```
