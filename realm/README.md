# Realm

适用于 Systemd / OpenRC ，以下命令以 root 执行。

| 文件 | 安装路径 |
| --- | --- |
| [config.toml](config.toml) | `/etc/realm/realm.toml` |
| [systemd unit](systemd/realm.service) | `/etc/systemd/system/realm.service` |
| [OpenRC 脚本](openrc/realm) | `/etc/init.d/realm` |

## 配置

安装后编辑 `/etc/realm/realm.toml`，将示例地址 `192.0.2.2:443` 替换为实际目标。默认监听 `0.0.0.0:5001`，仅转发 TCP。

- **`listen` / `remote`**：分别指定监听地址和转发目标。IPv6 地址需加方括号，如 `[2001:db8::1]:443`。
- **`no_tcp` / `use_udp`**：默认 `false`，即启用 TCP、禁用 UDP。需要同时转发 UDP 时，将 `use_udp` 设为 `true`。
- **`ipv6_only`**：默认 `false`。使用 `[::]:5001` 监听时，在支持双栈的系统上允许 IPv4 映射；`0.0.0.0:5001` 仅监听 IPv4。
- **`log`**：设置 `level = "info"`，日志默认输出至 `stdout`。OpenRC 可通过 logger 转入 syslog，systemd 则由 journal 收集。
- **多端口转发**：增加 `[[endpoints]]` 配置段，每段对应一组转发规则。

更多配置可参考 [官方示例](https://github.com/zhboner/realm/tree/master/examples)。

---


## Alpine

### 安装（OpenRC）

```sh
apk add --no-cache ca-certificates curl jq tar coreutils openrc busybox-openrc

REALM_VERSION=$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest | jq -er '.tag_name')
curl -fsSL "https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-$(uname -m)-unknown-linux-musl.tar.gz" | tar -xz -C /usr/local/bin realm
chmod +x /usr/local/bin/realm
/usr/local/bin/realm --version

mkdir -p /etc/realm
curl -fsSL https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/realm/config.toml -o /etc/realm/realm.toml

curl -fsSL https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/realm/openrc/realm -o /etc/init.d/realm
chmod +x /etc/init.d/realm

rc-update add syslog boot
rc-service syslog start
rc-update add realm default
rc-service realm start
rc-service realm status
```

### 管理（OpenRC）

```sh
rc-service realm start                 # 启动
rc-service realm stop                  # 停止
rc-service realm restart               # 重启
rc-service realm status                # 状态
rc-update add realm default            # 开机启动
rc-update del realm default            # 取消开机启动
tail -n 100 -f /var/log/messages | grep 'realm'  # 日志（BusyBox syslog 默认）
```

---
## Debian

### 安装（systemd）

```sh
apt update
apt install -y ca-certificates curl jq tar coreutils vim
# dnf install -y ca-certificates curl jq tar gzip coreutils vim 

REALM_VERSION=$(curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest | jq -er '.tag_name')
curl -fsSL "https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-$(uname -m)-unknown-linux-musl.tar.gz" | tar -xz -C /usr/local/bin realm
chmod +x /usr/local/bin/realm
/usr/local/bin/realm --version

mkdir -p /etc/realm
curl -fsSL https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/realm/config.toml -o /etc/realm/realm.toml

curl -fsSL https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/realm/systemd/realm.service -o /etc/systemd/system/realm.service

systemctl daemon-reload
systemctl enable --now realm
systemctl status realm --no-pager -l
```

### 管理（systemd）

```sh
systemctl start realm                  # 启动
systemctl stop realm                   # 停止
systemctl restart realm                # 重启
systemctl status realm --no-pager -l   # 状态
systemctl enable realm                 # 开机启动
systemctl disable realm                # 取消开机启动
journalctl -u realm -n 100 -f          # 日志
```
