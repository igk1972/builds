# mort

Custom build of [aldor007/mort](https://github.com/aldor007/mort) — an image processing
server written in Go. Built on Alpine (musl) against the system libvips and brotli; the
image is published to `ghcr.io/igk1972/mort`.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile): a
builder container compiles the binary, its rootfs is mounted via `buildah unshare`, and
the binary and configs are copied into a runtime container. The mort source is cloned from
upstream at `ref`; `build.sh` is a faithful translation of the original `Dockerfile.alpine`.

## Running

In CI — via `.github/workflows/mort.yml` (`workflow_dispatch`).

Locally the script only works on Linux (buildah). On a macOS/arm64 dev machine, copy
`projects/mort/` to a remote Linux/amd64 host and run it there over SSH:

```sh
# on a remote Linux/amd64 host:
MORT_REF=v0.37.0 PUSH=false ./build.sh     # dry run, no push
```

Environment variables: `MORT_REF`, `IMAGE`, `IMAGE_TAG`, `ALSO_TAG_LATEST`, `BASE_IMAGE`, `PUSH`.
