# frp

通过公网 VPS 访问内网主机上的单个服务。VPS 运行 `frps`，内网主机运行 `frpc`；本例将内网 SSH 映射到 VPS 的 `47001/TCP`。

```text
访问端 → VPS:47001 (frps) → 内网主机 (frpc) → 127.0.0.1:22
                            ↑
                 frpc 主动连接 VPS:47000
```

以下命令以 root 执行，适用于 Debian / Alpine 的 `x86_64`、`aarch64`。两端使用同一版本，按顺序安装，只启动各自角色。

| 文件 | 安装路径 |
| --- | --- |
| [frps.toml](frps.toml) | `/etc/frp/frps.toml`（VPS） |
| [frpc.toml](frpc.toml) | `/etc/frp/frpc.toml`（内网主机） |
| [frps.service](systemd/frps.service) / [frpc.service](systemd/frpc.service) | `/etc/systemd/system/` 下的同名文件 |
| [OpenRC frps](openrc/frps) / [OpenRC frpc](openrc/frpc) | `/etc/init.d/` 下的同名文件 |

## 配置说明

- **`serverAddr`**：在 `frpc.toml` 中改为 VPS 公网 IP 或域名。
- **`auth.token`**：在 VPS 执行 `openssl rand -hex 32` 生成一次随机值，填入两端，替换 `REPLACE_WITH_SAME_RANDOM_TOKEN`。这个 token 用于 frpc 登录 frps，访问 `47001` 端口仍由 SSH 自身认证。
- **`localIP` / `localPort`**：内网服务的地址和端口，默认是 frpc 所在机器的 SSH。访问另一台内网机器时，将 `localIP` 改为那台机器的内网 IP。

配置强制 frpc 与 frps 之间使用 TLS，但默认不验证 frps 的证书；需要校验服务端身份时，参考 [官方 TLS 配置](https://gofrp.org/zh-cn/docs/features/common/network/network-tls/)。SSH 仍应使用密钥登录并核对目标主机指纹。

## 安装二进制（两端执行）

Debian 安装依赖：

```sh
apt update
apt install -y ca-certificates curl jq tar gzip coreutils openssl vim
```

Alpine 安装依赖：

```sh
apk add --no-cache ca-certificates curl jq tar gzip coreutils openssl vim openrc busybox-openrc
```

```sh
(
    set -eu

    FRP_VERSION=$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest | jq -er '.tag_name')

    case "$(uname -m)" in
        x86_64) FRP_ARCH=amd64 ;;
        aarch64) FRP_ARCH=arm64 ;;
        *) echo "不支持的 CPU 架构，请选择官方发行包" >&2; exit 1 ;;
    esac

    FRP_PACKAGE="frp_${FRP_VERSION#v}_linux_${FRP_ARCH}"

    curl -fsSL "https://github.com/fatedier/frp/releases/download/${FRP_VERSION}/${FRP_PACKAGE}.tar.gz" \
        | tar -xz -C /usr/local/bin --strip-components=1 --no-same-owner \
            "$FRP_PACKAGE/frps" \
            "$FRP_PACKAGE/frpc"

    /usr/local/bin/frps --version
    /usr/local/bin/frpc --version
)
```

## 下载并编辑配置（两端执行）

下面是首次安装步骤，会写入对应配置文件。VPS 设置 `FRP_ROLE=frps`，内网主机改为 `FRP_ROLE=frpc`。先替换上述地址、token 和目标服务，再保存退出编辑器。

```sh
FRP_ROLE=frps  # 内网主机改为 frpc
(
    set -eu
    case "$FRP_ROLE" in frps|frpc) ;; *) exit 1 ;; esac
    mkdir -p /etc/frp
    curl -fsSL "https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/frp/${FRP_ROLE}.toml" -o "/etc/frp/${FRP_ROLE}.toml"
    "/usr/local/bin/$FRP_ROLE" verify -c "/etc/frp/${FRP_ROLE}.toml"
)
```

看到 `syntax is ok` 后再安装并启动服务。`verify` 只检查配置，不检查 token 是否已替换、两端是否一致，也不验证网络连通性。

## Debian（systemd）

在对应机器上设置角色；先启动 VPS 的 `frps`，再启动内网的 `frpc`。

```sh
FRP_ROLE=frps  # 内网主机改为 frpc
(
    set -eu
    case "$FRP_ROLE" in frps|frpc) ;; *) exit 1 ;; esac
    "/usr/local/bin/$FRP_ROLE" verify -c "/etc/frp/${FRP_ROLE}.toml"
    curl -fsSL "https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/frp/systemd/${FRP_ROLE}.service" -o "/etc/systemd/system/${FRP_ROLE}.service"

    systemctl daemon-reload
    systemctl enable --now "$FRP_ROLE"
    systemctl status "$FRP_ROLE" --no-pager -l
)
```

管理命令中的 `frps` 可替换为 `frpc`：

```sh
systemctl start frps
systemctl stop frps
systemctl restart frps
systemctl status frps --no-pager -l
systemctl enable frps
systemctl disable frps
journalctl -u frps -n 100 -f
```

## Alpine（OpenRC）

在对应机器上设置角色；先启动 VPS 的 `frps`，再启动内网的 `frpc`。

```sh
FRP_ROLE=frps  # 内网主机改为 frpc
(
    set -eu
    case "$FRP_ROLE" in frps|frpc) ;; *) exit 1 ;; esac
    "/usr/local/bin/$FRP_ROLE" verify -c "/etc/frp/${FRP_ROLE}.toml"
    curl -fsSL "https://raw.githubusercontent.com/zzwsec/tool/refs/heads/main/frp/openrc/${FRP_ROLE}" -o "/etc/init.d/${FRP_ROLE}"
    chmod +x "/etc/init.d/${FRP_ROLE}"

    rc-update add syslog boot
    rc-service syslog start
    rc-update add "$FRP_ROLE" default
    rc-service "$FRP_ROLE" start
    rc-service "$FRP_ROLE" status
)
```

管理命令中的 `frps` 可替换为 `frpc`：

```sh
rc-service frps start
rc-service frps stop
rc-service frps restart
rc-service frps status
rc-update add frps default
rc-update del frps default
tail -n 100 -f /var/log/messages | grep 'frps'
```

修改配置后，先运行对应的 `frps verify` 或 `frpc verify`，通过后重启对应服务。