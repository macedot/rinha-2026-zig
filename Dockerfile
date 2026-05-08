FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates xz-utils gcc && rm -rf /var/lib/apt/lists/*

ARG ZIG_VERSION=0.16.0
RUN wget -q "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && tar -xf "zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && mv "zig-x86_64-linux-${ZIG_VERSION}" /usr/local/zig \
    && rm "zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /src
COPY zig/build.zig zig/build.zig
COPY zig/src/ zig/src/
COPY resources/ resources/
COPY data/index.bin ./data/

# Build server
RUN cd zig && zig build -Dtarget=x86_64-linux-musl -Dcpu=haswell -Doptimize=ReleaseFast \
    && mkdir -p /app && cp zig-out/bin/rinha-server /app/server

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/server /app/server
COPY --from=build /src/data/index.bin /app/resources/index.bin

ENV INDEX_PATH=/app/resources/index.bin
ENV LISTEN_TCP=0
ENV IVF_NPROBE=8
ENV IVF_FULL_NPROBE=24
ENV CANDIDATES=0

ENTRYPOINT ["/app/server"]
