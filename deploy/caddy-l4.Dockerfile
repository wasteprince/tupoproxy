ARG CADDY_VERSION=2.11.4
FROM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_L4_VERSION=0.1.2
RUN xcaddy build --with github.com/mholt/caddy-l4@v${CADDY_L4_VERSION}

FROM caddy:${CADDY_VERSION}
LABEL org.opencontainers.image.source="https://github.com/wasteprince/tupoproxy"
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
