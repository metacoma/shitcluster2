# sing-box-lx (sing-box fork with XHTTP transport + AmneziaWG 2.0) baked image.
# Build stage: fetch the sing-box-lx release tarball.
FROM alpine:3.20 AS builder
RUN apk add --no-cache wget tar
ARG SB_TAG=v1.14.0-lx.26
ARG SB_FILE_VER=1.14.0-lx.26
ARG SB_URL=https://github.com/Leadaxe/sing-box-lx/releases/download/${SB_TAG}/sing-box-${SB_FILE_VER}-linux-amd64.tar.gz
RUN wget -q -O /tmp/sb.tar.gz ${SB_URL} \
    && mkdir -p /opt/singbox \
    && tar xzf /tmp/sb.tar.gz -C /opt/singbox --strip-components=1

# Runtime: alpine + iproute2 (real ip with policy-table support) + sing-box-lx
FROM alpine:3.20
RUN apk add --no-cache iproute2 ca-certificates
COPY --from=builder /opt/singbox/sing-box /usr/local/bin/sing-box
ENTRYPOINT ["sing-box"]
