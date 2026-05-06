FROM golang:1.24-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -ldflags="-s -w" -o /app/server ./cmd/server
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/build_index ./cmd/build_index

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/server /app/server
COPY --from=build /app/build_index /app/build_index
COPY resources/index.bin /app/resources/index.bin
COPY resources/mcc_risk.json /app/resources/mcc_risk.json

ENV INDEX_PATH=/app/resources/index.bin
ENV MCC_RISK_PATH=/app/resources/mcc_risk.json
ENV LISTEN_TCP=0
ENV IVF_NPROBE=1
ENV CANDIDATES=0

ENTRYPOINT ["/app/server"]
