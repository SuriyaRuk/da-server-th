# syntax=docker/dockerfile:1.7

# Self-contained multi-stage build for the Optimism AltDA `da-server`
# (op-alt-da/cmd/daserver). The builder clones the Optimism monorepo at build
# time, so this image builds from ANY context — including this standalone repo,
# which carries only the Docker/CI scaffolding and none of the Go source:
#
#   docker build -t da-server .
#
# Pin or swap the source with build args:
#   docker build --build-arg OPTIMISM_REF=v1.2.3 -t da-server .
#   docker build --build-arg OPTIMISM_REPO=https://github.com/you/fork -t da-server .
#
# The da-server stores commitments in S3 via the MinIO client. The Thailand zone
# is selected by --s3.endpoint=s3.ap-southeast-7.amazonaws.com, but minio-go's
# endpoint map doesn't know that region yet, so the builder also applies a small
# patch (see the "register the ap-southeast-7 endpoint" step below).

ARG GO_VERSION=1.24.13
ARG ALPINE_VERSION=3.22

# ---- builder ----------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

# blst / secp256k1 and other op-stack deps require CGO.
RUN apk add --no-cache gcc musl-dev linux-headers git make bash

WORKDIR /app

# Source of the Optimism monorepo (holds go.mod + op-alt-da/cmd/daserver and the
# replace directives the build needs). OPTIMISM_REF accepts a branch or tag.
ARG OPTIMISM_REPO=https://github.com/shikyo13/optimism-BB
ARG OPTIMISM_REF=develop

# Shallow-clone the monorepo at the requested ref into the build dir.
RUN git clone --depth 1 --branch "${OPTIMISM_REF}" "${OPTIMISM_REPO}" .

# Warm the module cache before the build.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

# ---- patch: register the ap-southeast-7 (Thailand) S3 endpoint ---------------
# daserver talks to S3 through minio-go, whose hardcoded AWS endpoint map has NO
# entry for ap-southeast-7 in any released version (verified through v7.2.0).
# Because of that, minio derives the signing region "ap-southeast-7" from the
# endpoint but then rewrites the request host to the us-east-1 endpoint, so AWS
# rejects every PUT with:
#   "The ap-southeast-7 location constraint is incompatible for the region
#    specific endpoint this request was sent to."
# We copy minio-go out of the module cache, drop in a same-package init() that
# adds the Thailand endpoint, and point the build at it with a local replace.
# (An init() file is used instead of sed so the patch is portable and survives
# minio-go bumps; remove it once minio-go ships ap-southeast-7 upstream.)
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build <<'PATCH'
set -eu
# Resolve the minio-go module directory in the cache. `go mod download` for the
# specific module guarantees it is extracted, because `go list -m -f '{{.Dir}}'`
# reports an EMPTY Dir for a module that has not been extracted yet. The guard
# below is critical: `set -e` does not abort on an empty command substitution in
# an assignment, so an empty MINIO_SRC would silently turn the cp below into
# `cp -a /. ...` — recursively copying the whole root filesystem (/proc, /sys),
# which is exactly the failure this replaces.
go mod download github.com/minio/minio-go/v7
MINIO_SRC="$(go list -m -f '{{.Dir}}' github.com/minio/minio-go/v7)"
if [ -z "${MINIO_SRC}" ] || [ ! -d "${MINIO_SRC}" ]; then
	echo "ERROR: could not resolve minio-go module directory (got: '${MINIO_SRC}')" >&2
	exit 1
fi
mkdir -p /patched/minio-go
cp -a "${MINIO_SRC}/." /patched/minio-go/
chmod -R u+w /patched/minio-go
cat > /patched/minio-go/s3-endpoints-thailand.go <<'EOF'
// Build-time patch (da-server image): register the AWS Asia Pacific (Thailand)
// region, absent from minio-go's endpoint map as of v7.2.0. Without it minio
// signs for ap-southeast-7 but sends to the us-east-1 host. Drop this file once
// minio-go registers ap-southeast-7 upstream.
package minio

func init() {
	awsS3EndpointMap["ap-southeast-7"] = awsS3Endpoint{
		"s3.ap-southeast-7.amazonaws.com",
		"s3.dualstack.ap-southeast-7.amazonaws.com",
	}
}
EOF
go mod edit -replace github.com/minio/minio-go/v7=/patched/minio-go
PATCH

# Version metadata (matches op-alt-da/justfile ldflags). VERSION can be
# overridden; the commit/date are derived from the cloned checkout.
ARG VERSION=v0.0.0

ENV CGO_ENABLED=1 GOOS=linux

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GIT_COMMIT="$(git rev-parse HEAD)"; \
    GIT_DATE="$(git show -s --format=%ct HEAD)"; \
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
