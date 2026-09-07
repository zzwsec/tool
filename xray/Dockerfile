ARG ALPINE_IMAGE="alpine:3.24"

FROM ${ALPINE_IMAGE} AS download

ARG XRAY_VERSION=v26.7.28
ARG JQ_VERSION=1.8.2
ARG TARGETARCH

RUN set -eux \
    && apk add --no-cache ca-certificates unzip \
    && case "$TARGETARCH" in \
        amd64) xray_asset="Xray-linux-64.zip"; jq_asset="jq-linux-amd64" ;; \
        arm64) xray_asset="Xray-linux-arm64-v8a.zip"; jq_asset="jq-linux-arm64" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${xray_asset}" \
    && mkdir -p /usr/local/share/xray \
    && unzip -j /tmp/xray.zip xray -d /usr/local/bin \
    && unzip -j /tmp/xray.zip geoip.dat geosite.dat -d /usr/local/share/xray \
    && rm -f /tmp/xray.zip \
    && wget -q -O /usr/local/bin/jq "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${jq_asset}" \
    && chmod 0755 /usr/local/bin/xray /usr/local/bin/jq

FROM ${ALPINE_IMAGE}

COPY --from=download /usr/local/bin/ /usr/local/bin/
COPY --from=download /usr/local/share/xray/ /usr/local/share/xray/
COPY --from=download /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV SNI=music.apple.com

WORKDIR /xray
EXPOSE 30000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]