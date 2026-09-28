#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/git-pages from igk1972/git-pages (a fork of
# codeberg.org/git-pages/git-pages) using explicit buildah commands (NO Dockerfile), published
# as a multi-arch (amd64+arm64) manifest. Rootless in CI/locally.
#
# Bare git-pages binary only, no Caddy/supervisord bundled — pair with ghcr.io/igk1972/caddy:s3
# for TLS termination and S3-backed cert storage (see projects/caddy). Pure Go, no CGO, so both
# arches cross-compile natively on amd64 without QEMU.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_PAGES_REPO="${GIT_PAGES_REPO:-https://github.com/igk1972/git-pages.git}"
GIT_PAGES_REF="${GIT_PAGES_REF:-develop}"
IMAGE="${IMAGE:-ghcr.io/igk1972/git-pages}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BUILDER_IMAGE="${BUILDER_IMAGE:-docker.io/library/golang:1.26-alpine}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-docker.io/library/alpine:3}"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"
PUSH="${PUSH:-true}"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WORK="$(mktemp -d)"
SRC_PARENT="$(mktemp -d)"; SRC_DIR="$SRC_PARENT/git-pages"
trap 'rm -rf "$WORK" "$SRC_PARENT"' EXIT

# 1. Upstream source at pinned ref (branch/tag; fallback fetch-by-sha)
if ! git clone --depth 1 --branch "$GIT_PAGES_REF" "$GIT_PAGES_REPO" "$SRC_DIR" 2>/dev/null; then
  git init "$SRC_DIR"; git -C "$SRC_DIR" remote add origin "$GIT_PAGES_REPO"
  git -C "$SRC_DIR" fetch --depth 1 origin "$GIT_PAGES_REF"; git -C "$SRC_DIR" checkout --detach FETCH_HEAD
fi
GIT_PAGES_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"

# 2. Cross-compile the binary for every platform in one native builder container.
#    --volume writes each binary straight to the host, so no buildah mount/unshare is needed.
bctr="$(buildah from "$BUILDER_IMAGE")"
buildah run "$bctr" -- apk add --no-cache git
buildah config --workingdir /build "$bctr"
buildah copy "$bctr" "$SRC_DIR/go.mod" /build/go.mod
buildah copy "$bctr" "$SRC_DIR/go.sum" /build/go.sum
buildah run "$bctr" -- go mod download
buildah copy "$bctr" "$SRC_DIR/main.go" /build/main.go
buildah copy "$bctr" "$SRC_DIR/src" /build/src
for pf in $PLATFORMS; do
  arch="${pf#linux/}"
  echo ">> building git-pages for $pf"
  buildah run \
    --volume "$WORK:/out" \
    --env GOOS=linux --env GOARCH="$arch" --env CGO_ENABLED=0 \
    "$bctr" -- go build -ldflags "-s -w" -trimpath -o "/out/git-pages-$arch" .
done
buildah rm "$bctr"

# Smoke test the native (amd64) binary; the arm64 one can't run on this runner.
if [ -x "$WORK/git-pages-amd64" ]; then
  "$WORK/git-pages-amd64" -version
fi

# 3. Assemble a multi-arch manifest and push its tags (<tag>, sha-<commit>).
MANIFEST="${IMAGE}:${IMAGE_TAG}"
buildah manifest rm "$MANIFEST" 2>/dev/null || true
buildah manifest create "$MANIFEST"
for pf in $PLATFORMS; do
  arch="${pf#linux/}"
  ctr="$(buildah from --arch "$arch" "$RUNTIME_IMAGE")"
  buildah run "$ctr" -- sh -eu -c '
    apk add --no-cache ca-certificates
    addgroup -g 1000 pages
    adduser -D -H -u 1000 -G pages pages
    mkdir -p /app/data
    chown -R pages:pages /app/data
  '
  buildah copy --chmod 0755 "$ctr" "$WORK/git-pages-$arch"    /usr/local/bin/git-pages
  buildah copy --chmod 0644 "$ctr" "$SCRIPT_DIR/config.toml" /app/config.toml
  buildah config \
    --workingdir /app --user pages \
    --port 3000 --port 3002 \
    --entrypoint '["/usr/local/bin/git-pages"]' --cmd '' \
    --label org.opencontainers.image.title=git-pages \
    --label "org.opencontainers.image.description=git-pages (static site server for Git forges), bare binary" \
    --label org.opencontainers.image.source=https://github.com/igk1972/builds \
    --label "org.opencontainers.image.revision=${GIT_PAGES_COMMIT}" \
    --label "org.opencontainers.image.created=${DATE}" \
    --label "org.opencontainers.image.version=${GIT_PAGES_REF}" \
    --label "org.opencontainers.image.url=${GIT_PAGES_REPO%.git}" \
    "$ctr"
  buildah commit --format docker --manifest "$MANIFEST" "$ctr"
  buildah rm "$ctr"
done

TAGS="${IMAGE_TAG} sha-${GIT_PAGES_COMMIT:0:12}"
if [ "$PUSH" = "true" ]; then
  for t in $TAGS; do
    buildah manifest push --all "$MANIFEST" "docker://${IMAGE}:${t}"
    echo ">> pushed: ${IMAGE}:${t}"
  done
else
  echo ">> PUSH=false: built manifest ${MANIFEST} locally (tags: ${TAGS}), not pushing"
fi
