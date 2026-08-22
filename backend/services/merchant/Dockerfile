# syntax=docker/dockerfile:1
# Multi-stage build for saarathi-merchant. Context is the backend/ workspace root.
# Cache mounts share compiled dependencies across the sibling service images.

FROM rust:1-slim-bookworm AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang pkg-config ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build --release --bin saarathi-merchant \
    && cp target/release/saarathi-merchant /usr/local/bin/service

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -m saarathi \
    && mkdir -p /data/merchant \
    && chown -R saarathi:saarathi /data
COPY --from=builder /usr/local/bin/service /usr/local/bin/service
USER saarathi
EXPOSE 8088
ENTRYPOINT ["/usr/local/bin/service"]
