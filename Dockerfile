FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates xz-utils && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && tar -xf "zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && mv "zig-x86_64-linux-${ZIG_VERSION}" /usr/local/zig \
    && rm "zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /src
COPY zig/build.zig zig/build.zig
COPY zig/src/ zig/src/
# Legacy C bridge and old index are gone. We use the 24 partitioned int16 .bin files.

# Create data dir. In release builds the 24 part*.bin files are expected
# to be present in the build context (pre-generated exactly like C repo).
RUN mkdir -p /app/data

# Copy pre-generated partitioned data if present in context (fast path)
COPY data/ /app/data/ 2>/dev/null || true

# Build pure Zig binary (haswell + musl target recommended)
RUN cd zig && zig build \
    -Dtarget=x86_64-linux-musl \
    -Dcpu=haswell \
    -Doptimize=ReleaseFast \
    && cp zig-out/bin/rinha-server /app/server

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/server /app/server

# Partitioned index directory (must contain the 24 partN_*.bin files
# produced by the C indexer that achieved 0/0 + 6000)
COPY data/ /app/data/

# INDEX_PATH is now a directory (matches winning C layout)
ENV INDEX_PATH=/app/data
ENV LISTEN_TCP=0
ENV UDS_PATH=/tmp/rinha.sock
ENV UDS_MODE=666
ENV UNLINK_UDS=1

ENTRYPOINT ["/app/server"]
