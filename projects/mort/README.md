# mort

Custom build of [aldor007/mort](https://github.com/aldor007/mort) — an S3-compatible
image processing / storage server in Go. Built on Alpine (musl) against the system
**libvips** and **brotli**, published as a container image to `ghcr.io/igk1972/mort`.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile):
a builder container compiles the CGO binary, its rootfs is mounted via `buildah unshare`,
and the binary + configs are copied into a runtime container. Source is cloned from
upstream at the given `ref`.

## Image

- `ghcr.io/igk1972/mort:<tag>` — plus `:latest` and `:sha-<commit>`.
- Runs as non-root user `mort` (uid 1000); config at `/etc/mort` (`MORT_CONFIG_DIR`).
- Ports **8080** (main) and **8081** (monitoring).
- No embedded HEALTHCHECK — `buildah commit` doesn't persist one (see note in `build.sh`);
  the entrypoint supports `mort -version` for a liveness probe.

```sh
docker run --rm ghcr.io/igk1972/mort:v0.37.0 -version
docker run -d -p 8080:8080 -p 8081:8081 ghcr.io/igk1972/mort:v0.37.0
```

## Building

CI: `.github/workflows/mort.yml` (`workflow_dispatch`, inputs `ref`, `image_tag`, …).
Locally (Linux only — buildah): copy `projects/mort/` to a remote Linux/amd64 host and
`MORT_REF=v0.37.0 PUSH=false ./build.sh` for a dry run.
