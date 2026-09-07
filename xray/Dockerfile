ARG ALPINE_IMAGE="alpine:3.24"

FROM ${ALPINE_IMAGE} AS download

ARG XRAY_VERSION=v26.7.28
ARG TARGETARCH

RUN set -eux \
    && apk add --no-cache ca-certificates jq \
    && apk add --no-cache --virtual .download-deps unzip \
    && case "$TARGETARCH" in \
        amd64) asset="Xray-linux-64.zip" ;; \
        arm64) asset="Xray-linux-arm64-v8a.zip" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${asset}" \
    && mkdir -p /usr/local/share/xray \
    && unzip -j /tmp/xray.zip xray -d /usr/local/bin \
    && unzip -j /tmp/xray.zip geoip.dat geosite.dat -d /usr/local/share/xray \
    && rm -f /tmp/xray.zip \
    && apk del .download-deps \
    && chmod 0755 /usr/local/bin/xray

FROM ${ALPINE_IMAGE}

COPY --from=download /usr/local/bin/xray /usr/local/bin/xray
COPY --from=download /usr/local/share/xray/ /usr/local/share/xray/
COPY --from=download /usr/bin/jq /usr/bin/jq
COPY --from=download /usr/lib/ /usr/lib/
COPY --from=download /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV SNI=music.apple.com

WORKDIR /xray
EXPOSE 30000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]