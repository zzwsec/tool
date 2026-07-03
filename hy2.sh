#!/usr/bin/env bash

set -eEuo pipefail

BASE_DOWN_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux"
BIN_FILENAME="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hysteria"
SERVICE_FILENAME="/etc/systemd/system/hysteria-server.service"
CF_API_TEST_URL="https://api.cloudflare.com/client/v4/user/tokens/verify"
CMD_LIST="jq wget curl openssl"
ARCH_TYPE="unknown"
PORT="443"
PACKAGE_TOOL=""
DOWN_URL=""
ACME_DOMAIN=""
ACME_EMAIL=""
CF_API_TOKEN=""
ZONE_NAME=""
PASSWORD=""

usage() {
    echo "Usage: $0 -t <CF_Token> -d <domain> -e <email> [-p password] [-z zone_name] [-P port]"
    echo "  -d  Set acme domain"
    echo "  -t  Set Cloudflare API Token"
    echo "  -e  Set ACME email"
    echo "  -p  Set connection password"
    echo "  -P  Set listen port (Default: 443)"
    echo "  -z  Set CF Zone name"
    echo "  -h  Show help message"
    exit 1
}

parse_args() {
    if [ $# -eq 0 ]; then
        usage
    fi

    while getopts "d:t:e:p:P:z:h" opt; do
        case $opt in
            d) ACME_DOMAIN="$OPTARG" ;;
            t) CF_API_TOKEN="$OPTARG" ;;
            e) ACME_EMAIL="$OPTARG" ;;
            p) PASSWORD="$OPTARG" ;;
            P) PORT="$OPTARG" ;;
            z) ZONE_NAME="$OPTARG" ;;
            h) usage ;;
            \?) usage ;;
        esac
    done

    if [ -z "$CF_API_TOKEN" ] || [ -z "$ACME_DOMAIN" ] || [ -z "$ACME_EMAIL" ]; then
        echo "Missing required parameters."
        echo "Must provide -t (Token), -d (Domain Name), and -e (Email)."
        usage
    fi

    if [ -z "$ZONE_NAME" ]; then
        ZONE_NAME="${ACME_DOMAIN#*.}"
    fi

    if [ -z "$PASSWORD" ]; then
        PASSWORD="$(openssl rand -hex 8)"
    fi
}

check_system() {
    echo "⏳ Checking system environment..."
    
    case "$(uname -m)" in
        x86_64|amd64)
            ARCH_TYPE="amd64"
            DOWN_URL="${BASE_DOWN_URL}-${ARCH_TYPE}"
            ;;
        aarch64|arm64)
            ARCH_TYPE="arm64"
            DOWN_URL="${BASE_DOWN_URL}-${ARCH_TYPE}"
            ;;
        *)
            echo "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    if [ ! -d /run/systemd/system ]; then
        echo "Current environment does not support systemd."
        exit 3
    fi

    if command -v apt-get &>/dev/null; then
        PACKAGE_TOOL="apt-get"
    elif command -v dnf &>/dev/null; then
        PACKAGE_TOOL="dnf"
    else
        echo "Unknown package manager tool."
        exit 2
    fi
}

install_deps() {
    echo "⏳ Updating package cache and installing dependencies..."
    if [ "$PACKAGE_TOOL" = "apt-get" ]; then
        $PACKAGE_TOOL update -q -y || { echo "Update package cache failed"; exit 1; }
    else
        $PACKAGE_TOOL makecache || { echo "Update package cache failed"; exit 1; }
    fi

    for cmd in $CMD_LIST; do
        if ! command -v "$cmd" &>/dev/null; then
            $PACKAGE_TOOL install -q -y "$cmd" || { echo "Install $cmd failed"; exit 1; }
        fi
    done
}

validate_cf_token() {
    echo "⏳ Verifying Cloudflare Token..."
    local resp
    resp=$(curl -s "${CF_API_TEST_URL}" -H "Authorization: Bearer ${CF_API_TOKEN}")
    if ! jq -e '.success == true and .result.status == "active"' &>/dev/null <<<"$resp"; then
        echo "CF token is not valid or lacks permissions."
        exit 1
    fi
}

download_hysteria() {
    echo "⏳ Downloading Hysteria 2 core..."
    if grep -qi "avx" /proc/cpuinfo; then
        wget "${DOWN_URL}-avx" -O "${BIN_FILENAME}"
    else
        wget "${DOWN_URL}" -O "${BIN_FILENAME}"
    fi
    chmod 755 "${BIN_FILENAME}"
}

setup_dns() {
    echo "⏳ Configuring Cloudflare DNS..."
    local ip zone_id
    ip=$(curl -s -4 -m 5 ip.sb || curl -s -4 -m 5 ipinfo.io/ip)
    zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ -z "$zone_id" ] || [ "$zone_id" == "null" ]; then
        echo "Unable to obtain Zone ID. Please check if the domain belongs to this CF account."
        exit 1
    fi

    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data '{
        "type": "A",
        "name": "'"$ACME_DOMAIN"'",
        "content": "'"$ip"'",
        "ttl": 60,
        "proxied": false
      }' | grep -q '"success":true' && echo "✅ DNS record added." || echo "⚠️ Adding A record failed (It may already exist)."
}

configure_and_start() {
    echo "⏳ Generating configurations and starting service..."
    mkdir -p "${CONFIG_DIR}/acme"

    cat > "${CONFIG_DIR}/config.yaml" <<EOF
listen: :${PORT}

acme:
  domains:
    - ${ACME_DOMAIN}
  email: ${ACME_EMAIL}
  ca: zerossl
  type: dns
  dir: ${CONFIG_DIR}/acme
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: ${CF_API_TOKEN}

bandwidth:
  up: 500 mbps
  down: 50 mbps

outbounds:
  - name: direct_output 
    type: direct
    direct:
      mode: 64
    fastOpen: true

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://www.nus.edu.sg/
    rewriteHost: true
EOF

    if ! id "hysteria" &>/dev/null; then
        useradd -r -d /var/lib/hysteria -m hysteria
    fi
    chown -R hysteria:hysteria /etc/hysteria

    cat > "${SERVICE_FILENAME}" <<EOF
[Unit]
Description=Hysteria Server Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_FILENAME} server --config ${CONFIG_DIR}/config.yaml
WorkingDirectory=~
User=hysteria
Group=hysteria
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=1048576
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now hysteria-server
    systemctl status hysteria-server --no-pager -l
    sleep 3
}

print_summary() {
    clear
    cat <<EOF
=======================================================
✅ Hysteria 2 Installation Completed!
=======================================================

Option 1: YAML Config
-------------------------------------------------------
proxies:
  - name: "Apernet-SG"
    type: hysteria2
    server: ${ACME_DOMAIN}
    port: ${PORT}
    password: "${PASSWORD}"
    sni: ${ACME_DOMAIN}
    up: 50 Mbps       # Client upload limit
    down: 500 Mbps    # Client download limit
    skip-cert-verify: false
    alpn:
      - h3
-------------------------------------------------------

Option 2: URI Scheme
-------------------------------------------------------
hy2://${PASSWORD}@${ACME_DOMAIN}:${PORT}?sni=${ACME_DOMAIN}&up=50mbps&down=500mbps#Apernet-SG
-------------------------------------------------------

📌 Important Notes
1. UDP Port: Ensure UDP ${PORT} is allowed in your VPS firewall/security group.
2. Brutal vs BBR: Adjust 'up' and 'down' values to your actual local network speed to enable Brutal congestion control. To fallback to BBR (recommended for unstable mobile networks), simply remove 'up' and 'down' parameters.
EOF
}

main() {
    parse_args "$@"
    check_system
    install_deps
    validate_cf_token
    download_hysteria
    setup_dns
    configure_and_start
    print_summary
}

main "$@"
