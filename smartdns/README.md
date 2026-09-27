# SmartDNS

Debian / Ubuntu，以下命令以 root 执行。

[配置文件](smartdns.conf) · [官方示例](https://github.com/pymumu/smartdns/blob/master/etc/smartdns/smartdns.conf)

## 📦 安装与配置

```shell
apt update
apt install -y smartdns dnsutils ca-certificates

cp -a /etc/smartdns/smartdns.conf /tmp/smartdns.conf.bak
curl -fsSL https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/smartdns/smartdns.conf -o /etc/smartdns/smartdns.conf

systemctl enable smartdns
systemctl restart smartdns
systemctl status smartdns --no-pager -l

dig @127.0.0.1 example.com
dig +tcp @127.0.0.1 example.com
```

## ⚙️ 关键配置

- `bind` / `bind-tcp`：仅监听本机 `127.0.0.1:53`，支持 UDP 和 TCP。
- `server`：使用 Cloudflare、Google、Quad9 上游；没有 IPv6 网络时，删除三个 IPv6 上游。
- `speed-check-mode` / `response-mode fastest-ip`：对解析出的 IP 测速并优选，首次查询可能稍慢。
- `cache-*`：缓存容量 20480 条，持久化到 `/var/cache/smartdns.cache`，每小时保存一次。
- `dualstack-ip-selection no`：关闭 IPv4 / IPv6 之间的优选，不禁用 AAAA 解析。
- `rr-ttl-min` / `rr-ttl-max`：TTL 限制为 300～1800 秒。
- `prefetch-domain yes` / `serve-expired no`：预取缓存，不返回过期记录。
- `log-level warn` / `audit-enable no`：仅记录警告及更严重的日志，关闭查询审计。

## 🌐 设置系统 DNS

确认上述查询成功后，若 `/etc/resolv.conf` 为手动维护的普通文件：

```shell
cp -a /etc/resolv.conf /tmp/resolv.conf.bak
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
dig example.com
```

若 DNS 由 systemd-resolved、NetworkManager 或 Netplan 管理，在对应配置中设置 `127.0.0.1`。

使用 `/etc/network/interfaces` 且已接入 resolvconf 时，在网卡的 `iface` 段添加：

```text
dns-nameservers 127.0.0.1
```
