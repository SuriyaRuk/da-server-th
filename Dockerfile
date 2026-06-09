# syntax=docker/dockerfile:1.7

# Self-contained multi-stage build for the Optimism AltDA `da-server`
# (op-alt-da/cmd/daserver). Build context MUST be the repository root so the
# monorepo go.mod / replace directives resolve.
#
#   docker build -f Dockerfile -t da-server .
#
# The da-server already supports S3 storage via the MinIO client. Selecting the
# Thailand zone is purely a matter of pointing --s3.endpoint at the AWS Asia
# Pacific (Thailand) regional endpoint: s3.ap-southeast-7.amazonaws.com

ARG GO_VERSION=1.24.13
ARG ALPINE_VERSION=3.22

# ---- builder ----------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

# blst / secp256k1 and other op-stack deps require CGO.
RUN apk add --no-cache gcc musl-dev linux-headers git make bash

WORKDIR /app

# Warm the module cache first for faster incremental builds.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

# Bring in the full monorepo (needed for local packages + replace directives).
COPY . .

# Version metadata (matches op-alt-da/justfile ldflags).
ARG VERSION=v0.0.0
ARG GIT_COMMIT=""
ARG GIT_DATE=""

ENV CGO_ENABLED=1 GOOS=linux

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath \
      -ldflags "-X main.Version=${VERSION} -X main.GitCommit=${GIT_COMMIT} -X main.GitDate=${GIT_DATE}" \
      -o /usr/local/bin/da-server \
      ./op-alt-da/cmd/daserver

# ---- runtime ----------------------------------------------------------------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata wget \
    && cp /usr/share/zoneinfo/Asia/Bangkok /etc/localtime \
    && echo "Asia/Bangkok" > /etc/timezone \
    && addgroup -S daserver && adduser -S -G daserver daserver

COPY --from=builder /usr/local/bin/da-server /usr/local/bin/da-server

# Defaults: listen on all interfaces; the Thailand S3 endpoint is the default
# so the image is "Thailand zone" out of the box. Override any OP_ALTDA_SERVER_*
# value at runtime. Credentials and bucket MUST be supplied at run time.
ENV OP_ALTDA_SERVER_ADDR=0.0.0.0 \
    OP_ALTDA_SERVER_PORT=3100 \
    OP_ALTDA_SERVER_S3_ENDPOINT=s3.ap-southeast-7.amazonaws.com

EXPOSE 3100
USER daserver

# Simple liveness check against the listening port.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:3100/ || exit 1

ENTRYPOINT ["da-server"]
