# syntax=docker/dockerfile:1
# Multi-stage build for saarathi-auth.
#
# Build context is the backend/ Cargo workspace root (see docker-compose.yml) —
# the whole workspace is needed because services share the saarathi-core crate.
# BuildKit cache mounts share the cargo registry + compiled target dir across all
# seven service images, so dependencies are compiled once, not seven times.

FROM rust:1-slim-bookworm AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential clang pkg-config ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build --release --bin saarathi-auth \
    && cp target/release/saarathi-auth /usr/local/bin/service

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 -m saarathi \
    && mkdir -p /data/kyc \
    && chown -R saarathi:saarathi /data
COPY --from=builder /usr/local/bin/service /usr/local/bin/service
USER saarathi
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/service"]
