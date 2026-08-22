# syntax=docker/dockerfile:1

# Build this working tree so local fork changes are never replaced by a
# downloaded release artifact.
FROM rust:slim-bookworm AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential ca-certificates pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY benches ./benches
RUN cargo build --release --locked --bin tupoproxy

FROM debian:12-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 65532 tupoproxy \
    && useradd --system --uid 65532 --gid tupoproxy --home-dir /app --shell /usr/sbin/nologin tupoproxy

WORKDIR /app
COPY --from=builder /src/target/release/tupoproxy /app/tupoproxy
COPY config.toml /app/config.toml

USER tupoproxy:tupoproxy
EXPOSE 443 9090 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/app/tupoproxy", "healthcheck", "/app/config.toml", "--mode", "liveness"]
ENTRYPOINT ["/app/tupoproxy"]
CMD ["/app/config.toml"]

FROM runtime AS prod

FROM runtime AS debug

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl iproute2 busybox \
    && rm -rf /var/lib/apt/lists/*
USER tupoproxy:tupoproxy

FROM debian:12-slim AS prod-netfilter

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata conntrack nftables iptables \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 65532 tupoproxy \
    && useradd --system --uid 65532 --gid tupoproxy --home-dir /app --shell /usr/sbin/nologin tupoproxy

WORKDIR /app
COPY --from=builder /src/target/release/tupoproxy /app/tupoproxy
COPY config.toml /app/config.toml

EXPOSE 443 9090 9091
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/app/tupoproxy", "healthcheck", "/app/config.toml", "--mode", "liveness"]
ENTRYPOINT ["/app/tupoproxy"]
CMD ["/app/config.toml"]
