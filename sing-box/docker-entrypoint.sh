#!/bin/sh
set -eu
umask 077

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

config=/sing-box/config.json

if [ -e "$config" ]; then
    [ -f "$config" ] && [ -s "$config" ] && [ -r "$config" ] \
        || die "$config exists but must be a readable, non-empty regular file."

    printf 'Using existing %s.\n' "$config"
    sing-box check -D /sing-box/data -c "$config"
    exec sing-box run -D /sing-box/data -c "$config"
fi

SNI=${SNI:-music.apple.com}

mkdir -p /sing-box/data

credentials=/sing-box/data/credentials.json
if [ -e "$credentials" ]; then
    UUID=$(jq -r .uuid "$credentials")
    PRIVATE_KEY=$(jq -r .privateKey "$credentials")
    PUBLIC_KEY=$(jq -r .publicKey "$credentials")
    SHORT_ID=$(jq -r .shortId "$credentials")
    [ -n "$UUID" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] || die "Invalid credentials file: $credentials"
else
    UUID=$(sing-box generate uuid)
    keys=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(printf '%s\n' "$keys" | awk '/^PrivateKey:/ {print $2; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$keys" | awk '/^PublicKey:/ {print $2; exit}')
    [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die 'Could not parse REALITY keypair.'
    SHORT_ID=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')

    jq -n \
        --arg uuid "$UUID" \
        --arg key "$PRIVATE_KEY" \
        --arg pub "$PUBLIC_KEY" \
        --arg sid "$SHORT_ID" \
        '{uuid: $uuid, privateKey: $key, publicKey: $pub, shortId: $sid}' >"$credentials"
fi

config_tmp=$(mktemp /sing-box/config.XXXXXX)
link_tmp=$(mktemp /sing-box/data/link.XXXXXX)

trap 'rm -f "$config_tmp" "$link_tmp"' EXIT
trap 'exit 1' HUP INT TERM

jq -n \
    --arg sni "$SNI" \
    --arg uuid "$UUID" \
    --arg key "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" '
{
  log: {
    level: "warn",
    timestamp: true
  },
  dns: {
    servers: [{
      type: "local",
      tag: "local-dns"
    }],
    strategy: "prefer_ipv4"
  },
  inbounds: [{
    type: "vless",
    tag: "reality-in",
    listen: "::",
    listen_port: 30000,
    users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
    tls: {
      enabled: true,
      server_name: $sni,
      reality: {
        enabled: true,
        handshake: {server: $sni, server_port: 443},
        private_key: $key,
        short_id: [$sid]
      }
    }
  }],
  outbounds: [{
    type: "direct",
    tag: "direct-out"
  }],
  http_clients: [{
    tag: "direct-http"
  }],
  route: {
    default_domain_resolver: "local-dns",
    default_http_client: "direct-http",
    rule_set: [{
      type: "remote",
      tag: "geosite-meituan",
      format: "binary",
      url: "https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-meituan.srs",
      update_interval: "1d"
    }],
    rules: [
      {action: "sniff"},
      {protocol: "bittorrent", action: "reject"},
      {domain_suffix: ["ping0.cc"], action: "reject"},
      {rule_set: ["geosite-meituan"], action: "reject"},
      {action: "resolve", server: "local-dns"},
      {ip_is_private: true, action: "reject"}
    ],
    final: "direct-out"
  },
  experimental: {
    cache_file: {
      enabled: true
    }
  }
}' >"$config_tmp"

sing-box check -D /sing-box/data -c "$config_tmp"

address=
for endpoint in https://ipv4.ip.sb https://ipv6.ip.sb; do
    address=$(wget -qO- -T 3 "$endpoint" 2>/dev/null | tr -d '[:space:]')
    [ -n "$address" ] && break
done

if [ -n "$address" ]; then
    case "$address" in
        \[*\]) ;;
        *:*) address="[$address]" ;;
    esac

    printf 'vless://%s@%s:30000?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=%s&pbk=%s&sid=%s&fp=firefox#REALITY\n' \
        "$UUID" "$address" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" >"$link_tmp"
fi

mv -f "$config_tmp" "$config"
mv -f "$link_tmp" /sing-box/data/link.txt

if [ -s /sing-box/data/link.txt ]; then
    printf '\n%s\n' '---------------- VLESS LINK ----------------'
    cat /sing-box/data/link.txt
    printf '%s\n\n' '--------------------------------------------'
else
    printf 'Warning: Public IP lookup failed; VLESS link was not generated. sing-box will still start.\n' >&2
fi

exec sing-box run -D /sing-box/data -c "$config"
