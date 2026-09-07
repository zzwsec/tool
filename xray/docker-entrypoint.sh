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

if [ -e /xray/config.json ]; then
    [ -f /xray/config.json ] && [ -s /xray/config.json ] && [ -r /xray/config.json ] \
        || die '/xray/config.json must be a readable, non-empty file.'

    printf 'Using existing /xray/config.json.\n'
    xray run -test -config /xray/config.json
    exec xray run -config /xray/config.json
fi

SNI=${SNI:-music.apple.com}
REALITY_TARGET="$SNI:443"

mkdir -p /xray/data

credentials=/xray/data/credentials.json
if [ -e "$credentials" ]; then
    jq -e 'type == "object" and
        (.uuid | type == "string" and length > 0) and
        (.privateKey | type == "string" and length > 0) and
        (.shortId | type == "string" and test("^([0-9a-fA-F]{2}){1,8}$"))' \
        "$credentials" >/dev/null || die "Invalid credentials file: $credentials"

    UUID=$(jq -r .uuid "$credentials")
    PRIVATE_KEY=$(jq -r .privateKey "$credentials")
    SHORT_ID=$(jq -r .shortId "$credentials")
else
    UUID=$(xray uuid)
    PRIVATE_KEY=
    SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 16)
fi

if [ -n "$PRIVATE_KEY" ]; then
    keys=$(xray x25519 -i "$PRIVATE_KEY")
else
    keys=$(xray x25519)
fi

PRIVATE_KEY=$(printf '%s\n' "$keys" | awk -F ': ' '/^PrivateKey:/ {print $2; exit}')
PUBLIC_KEY=$(printf '%s\n' "$keys" | awk -F ': ' '/^Password \(PublicKey\):/ {print $2; exit}')
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || die 'Could not parse xray x25519 output.'

config_tmp=$(mktemp /xray/config.XXXXXX)
credentials_tmp=$(mktemp /xray/data/credentials.XXXXXX)
link_tmp=$(mktemp /xray/data/link.XXXXXX)

trap 'rm -f "$config_tmp" "$credentials_tmp" "$link_tmp"' EXIT
trap 'exit 1' HUP INT TERM

jq -n \
    --arg uuid "$UUID" \
    --arg key "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" \
    '{uuid: $uuid, privateKey: $key, shortId: $sid}' >"$credentials_tmp"

jq -n \
    --arg sni "$SNI" \
    --arg target "$REALITY_TARGET" \
    --arg uuid "$UUID" \
    --arg key "$PRIVATE_KEY" \
    --arg sid "$SHORT_ID" '
{
  log: {
    loglevel: "warning"
  },
  inbounds: [{
    tag: "vless-reality",
    listen: "0.0.0.0",
    port: 30000,
    protocol: "vless",
    settings: {
      clients: [{
        id: $uuid,
        flow: "xtls-rprx-vision"
      }],
      decryption: "none"
    },
    streamSettings: {
      method: "raw",
      security: "reality",
      realitySettings: {
        target: $target,
        serverNames: [$sni],
        privateKey: $key,
        minClientVer: "1.8.2",
        shortIds: [$sid]
      }
    },
    sniffing: {
      enabled: true,
      destOverride: ["http", "quic", "tls"],
      routeOnly: true
    }
  }],
  outbounds: [
    {tag: "direct", protocol: "freedom"},
    {tag: "block", protocol: "blackhole"}
  ],
  routing: {
    domainStrategy: "IPIfNonMatch",
    rules: [
      {
        type: "field",
        protocol: ["bittorrent"],
        outboundTag: "block"
      },
      {
        type: "field",
        ip: ["geoip:private"],
        outboundTag: "block"
      },
      {
        type: "field",
        domain: ["geosite:meituan", "domain:ping0.cc"],
        outboundTag: "block"
      }
    ]
  }
}' >"$config_tmp"

xray run -test -format json -config "$config_tmp"

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

mv -f "$credentials_tmp" "$credentials"
mv -f "$config_tmp" /xray/config.json
mv -f "$link_tmp" /xray/data/link.txt

if [ -s /xray/data/link.txt ]; then
    printf '\n%s\n' '---------------- VLESS LINK ----------------'
    cat /xray/data/link.txt
    printf '%s\n\n' '--------------------------------------------'
else
    printf 'Warning: Public IP lookup failed; VLESS link was not generated. Xray will still start.\n' >&2
fi

exec xray run -config /xray/config.json