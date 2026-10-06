# moq-relay 0.13.5 — the version this demo is pinned to (pairs with moq-cli
# 0.11.2 on the publisher). Built from crates.io; multi-arch (arm64 + x86_64).
FROM rust:1-bookworm AS build
RUN cargo install moq-relay --locked --version 0.13.5

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/cargo/bin/moq-relay /usr/local/bin/
ENTRYPOINT ["moq-relay"]
