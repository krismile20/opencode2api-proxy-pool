# syntax=docker/dockerfile:1

ARG OC2A_REPO=https://github.com/jasonxu114514/opencode2api
ARG EP_REPO=https://github.com/jasonwong1991/easy_proxies
ARG OC2A_REF=2615455b87f01f35ad125ebbf15d76257834da24
ARG EP_REF=d423519c74603f5a22a7e6f9b9545137cc705a2e

FROM golang:1.24-alpine AS builder
ARG OC2A_REPO
ARG EP_REPO
ARG OC2A_REF
ARG EP_REF
ARG GOPROXY=https://goproxy.cn,direct

RUN apk add --no-cache git ca-certificates \
 && go env -w GOPROXY="${GOPROXY}"

RUN git clone "${OC2A_REPO}" /src/opencode2api \
 && git -C /src/opencode2api checkout --detach "${OC2A_REF}" \
 && git clone "${EP_REPO}" /src/easy_proxies \
 && git -C /src/easy_proxies checkout --detach "${EP_REF}"

RUN sed -i "s|'/api/|'/oc2a/api/|g" /src/opencode2api/webui/index.html \
 && sed -i "s|'/api/|'/pool/api/|g" /src/easy_proxies/internal/monitor/assets/index.html

RUN cd /src/opencode2api \
 && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/opencode2api .

RUN cd /src/easy_proxies \
 && CGO_ENABLED=0 go build -trimpath -tags "with_utls with_quic with_grpc" -ldflags "-s -w" -o /out/easy_proxies ./cmd/easy_proxies

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata supervisor python3 \
 && rm -rf /var/lib/apt/lists/* \
 && apt-get clean

COPY --from=caddy:2 /usr/bin/caddy /usr/local/bin/caddy
COPY --from=builder /out/opencode2api /usr/local/bin/opencode2api
COPY --from=builder /out/easy_proxies /usr/local/bin/easy_proxies

COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY start.sh /usr/local/bin/start.sh
COPY web/ /srv/portal/

RUN chmod +x /usr/local/bin/start.sh \
 && useradd --system --uid 10001 --home-dir /run/app --shell /usr/sbin/nologin appuser \
 && mkdir -p /run/app \
 && chown -R appuser:appuser /run/app

USER appuser

ENV PORT=8080

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]
