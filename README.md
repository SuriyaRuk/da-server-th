# da-server Docker image (AWS Thailand / ap-southeast-7 S3)

Packages the Optimism AltDA `da-server`
([`op-alt-da/cmd/daserver`](https://github.com/shikyo13/optimism-BB/tree/develop/op-alt-da/cmd/daserver))
as a Docker image, published publicly to GitHub Container Registry, and
preconfigured for the **AWS Asia Pacific (Thailand)** S3 zone, `ap-southeast-7`.

## How S3 / the Thailand zone works

`da-server` stores AltDA inputs through the MinIO S3 client. It exposes four S3
settings — bucket, endpoint, access key, secret — and **no separate region
flag**: the region is determined entirely by the endpoint hostname. To target
Thailand you point the endpoint at `s3.ap-southeast-7.amazonaws.com`, which this
image uses as its default.

| Flag | Env var | Value for Thailand |
|------|---------|--------------------|
| `--s3.endpoint` | `OP_ALTDA_SERVER_S3_ENDPOINT` | `s3.ap-southeast-7.amazonaws.com` |
| `--s3.bucket` | `OP_ALTDA_SERVER_S3_BUCKET` | your bucket (created in ap-southeast-7) |
| `--s3.access-key-id` | `OP_ALTDA_SERVER_S3_ACCESS_KEY_ID` | your key id |
| `--s3.access-key-secret` | `OP_ALTDA_SERVER_S3_ACCESS_KEY_SECRET` | your secret |
| `--addr` | `OP_ALTDA_SERVER_ADDR` | `0.0.0.0` |
| `--port` | `OP_ALTDA_SERVER_PORT` | `3100` |

The server requires exactly one backend. With any S3 var set it uses S3; leave
them empty and set `--file.path` to use local file storage instead.

> The same setup works for any S3-compatible service hosted in Thailand (e.g.
> self-hosted MinIO) — just change the endpoint.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Self-contained multi-stage build of `da-server`. |
| `.dockerignore` | Trims VCS metadata from the build context. |
| `docker-publish.yml` | GitHub Actions workflow → publishes to `ghcr.io`. |
| `docker-compose.yml` | One-command local run, wired to the Thailand endpoint. |
| `.env.example` | Template for credentials / bucket. |

## Install into the repo

These files build from the **repository root** (the monorepo `go.mod` and its
`replace` directives are required). From your clone of `shikyo13/optimism-BB`:

```bash
cp Dockerfile .dockerignore docker-compose.yml .env.example .       # repo root
mkdir -p .github/workflows
cp docker-publish.yml .github/workflows/
```

## Build & run locally

```bash
# from the repo root
docker build -t da-server .

cp .env.example .env        # then edit credentials/bucket
docker compose up -d        # or: docker run --env-file .env -p 3100:3100 da-server
```

Quick check:

```bash
curl -i http://localhost:3100/        # server is up
# store / retrieve via the AltDA REST API (PUT /put, GET /get/<commitment>)
```

## Publish to GitHub Container Registry (public)

1. Commit the files and push to `develop`/`main`, or push a `vX.Y.Z` tag.
2. The workflow builds `linux/amd64` + `linux/arm64` and pushes to
   `ghcr.io/<owner>/da-server`. No secrets needed — it uses the built-in
   `GITHUB_TOKEN`.
3. First time only: make the package public — repo **Packages → da-server →
   Package settings → Change visibility → Public**.

Then anyone can pull:

```bash
docker pull ghcr.io/shikyo13/da-server:latest
```

## Notes

- **CGO** is enabled in the build (op-stack deps such as `blst` need it); the
  builder installs `gcc`/`musl-dev` accordingly.
- The image sets its timezone to `Asia/Bangkok`.
- It runs as a non-root `daserver` user and exposes port `3100`.
- Version stamping mirrors `op-alt-da/justfile` (`-X main.Version`, etc.).
