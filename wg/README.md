# WireGuard

## 安装

### Debian / Ubuntu

```sh
apt update
apt install -y wireguard-tools iptables curl ca-certificates
```

### Alpine

```sh
apk add --no-cache wireguard-tools wireguard-tools-openrc iptables curl ca-certificates
```

## 服务端配置

### 1. 生成服务端密钥

```sh
install -d -m 700 /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee privatekey | wg pubkey > publickey
```

### 2. 生成配置文件

获取默认出口网卡并生成 `/etc/wireguard/wg0.conf`：

```sh
privatekey=$(cat /etc/wireguard/privatekey)
cni=$(ip -4 r s default | awk '{print $5}')

cat <<EOF >/etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${privatekey}
Address = 10.8.0.1/24
ListenPort = 30020
PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${cni} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${cni} -j MASQUERADE
EOF
chmod 600 /etc/wireguard/wg0.conf
```

### 3. 开启 IPv4 转发

```sh
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf
```

### 4. 启动服务

Debian：

```sh
systemctl enable --now wg-quick@wg0
systemctl status wg-quick@wg0 --no-pager -l
```

Alpine：

```sh
ln -s /etc/init.d/wg-quick /etc/init.d/wg-quick.wg0
rc-update add wg-quick.wg0 default
rc-service wg-quick.wg0 start
rc-service wg-quick.wg0 status
```

云服务器安全组或路由器端口映射需放行 **UDP 30020**。

## 添加客户端（Peer）

### 1. 生成客户端密钥

在服务端（或客户端本地）执行：

```sh
cd /etc/wireguard
umask 077
wg genkey | tee client1-privatekey | wg pubkey > client1-publickey
```

### 2. 服务端追加 Peer

```sh
client_publickey=$(cat /etc/wireguard/client1-publickey)

cat <<EOF >>/etc/wireguard/wg0.conf

[Peer]
PublicKey = ${client_publickey}
AllowedIPs = 10.8.0.2/32
EOF
```

> 新增多个客户端时依次分配不同的隧道地址，如 `10.8.0.3/32`、`10.8.0.4/32`。

### 3. 热加载配置

不建议直接使用 `restart`（会导致 `wg0` 网卡被物理销毁并重建、造成连接中断），推荐使用 `syncconf` 进行平滑热加载：

```sh
wg syncconf wg0 <(wg-quick strip wg0)
```

## 客户端配置

Windows / macOS / Android / iOS 可直接导入此配置，Linux 客户端保存至 `/etc/wireguard/wg0.conf`：

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.8.0.2/24
MTU = 1400

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
Endpoint = <SERVER_IP>:30020
AllowedIPs = 10.8.0.0/24, 10.46.96.0/22
PersistentKeepalive = 15
```

- **分流 / 全流量**：
  - 仅内网与局域网段走服务端：`AllowedIPs = 10.8.0.0/24, 10.46.96.0/22`
  - 全部网络流量走服务端：`AllowedIPs = 0.0.0.0/0`
- **保活设置**：
  - `PersistentKeepalive = 15` 用于维持客户端 NAT 映射；移动端不建议开启保活，会增加电量消耗。
- **客户端下载**：
  - Windows：[官方 Windows 客户端下载](https://download.wireguard.com/windows-client/)
  - 全平台客户端参考 [WireGuard 官方安装页](https://www.wireguard.com/install/)

## 验证与管理

在客户端测试握手与连通性：

```sh
wg show
ping -c 3 10.8.0.1
```

服务管理命令：

```sh
# Debian
systemctl restart wg-quick@wg0
systemctl stop wg-quick@wg0
journalctl -u wg-quick@wg0 -n 100 -f

# Alpine
rc-service wg-quick.wg0 restart
rc-service wg-quick.wg0 stop
```
