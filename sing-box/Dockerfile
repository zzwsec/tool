ARG ALPINE_IMAGE="alpine:3.24"

FROM ${ALPINE_IMAGE} AS download

ARG SING_BOX_VERSION=1.14.0
ARG JQ_VERSION=1.8.2
ARG TARGETARCH

RUN set -eux \
    && case "$TARGETARCH" in \
        amd64) sb_asset="sing-box-${SING_BOX_VERSION}-linux-amd64-musl"; jq_asset="jq-linux-amd64" ;; \
        arm64) sb_asset="sing-box-${SING_BOX_VERSION}-linux-arm64-musl"; jq_asset="jq-linux-arm64" ;; \
        *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && wget -q -O- "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${sb_asset}.tar.gz" \
        | tar xzf - -C /usr/local/bin --strip-components=1 "${sb_asset}/sing-box" \
    && wget -q -O /usr/local/bin/jq "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${jq_asset}" \
    && chmod 755 /usr/local/bin/sing-box /usr/local/bin/jq

FROM ${ALPINE_IMAGE}

COPY --from=download /usr/local/bin/ /usr/local/bin/
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

ENV SNI=music.apple.com

WORKDIR /sing-box
EXPOSE 30000/tcp
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]