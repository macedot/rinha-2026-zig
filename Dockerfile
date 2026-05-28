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

# Create data dir (the actual index files are loaded at runtime from $INDEX_PATH).
RUN mkdir -p /app/data

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

# Partitioned index directory.
# The 24 partN_*.bin files are required at runtime (same as the C implementation).
# We create the directory so the image is always valid.
#
# For a complete self-contained production image:
#   - Ensure the files are present in ./data/ in the build context before `docker build`
#     (the release workflow / CI can prepare them), or
#   - Mount them at runtime via volume at $INDEX_PATH.
RUN mkdir -p /app/data

# INDEX_PATH is a directory containing the partitioned index (matches winning C layout)
ENV INDEX_PATH=/app/data
ENV LISTEN_TCP=0
ENV UDS_PATH=/tmp/rinha.sock
ENV UDS_MODE=666
ENV UNLINK_UDS=1

ENTRYPOINT ["/app/server"]
