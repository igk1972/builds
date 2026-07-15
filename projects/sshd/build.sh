#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/sshd from the igk1972/sshd base image: add a non-root 'user'
# and a hardened sshd_config, using explicit buildah commands (NO Dockerfile).
# amd64 only. Rootless in CI and locally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${IMAGE:-ghcr.io/igk1972/sshd}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BASE_IMAGE="${BASE_IMAGE:-docker.io/igk1972/sshd:9.2-alpine}"
PUSH="${PUSH:-true}"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ctr="$(buildah from "$BASE_IMAGE")"
cleanup() { buildah rm "$ctr" 2>/dev/null || true; }
trap cleanup EXIT

buildah run "$ctr" -- sh -eu -c '
  addgroup -g 1000 user
  adduser -D -u 1000 -G user -s /bin/false user
  passwd -u user
'
buildah copy --chmod 0600 "$ctr" "$SCRIPT_DIR/sshd_config" /etc/ssh/sshd_config

# Inherit the base image entrypoint/cmd (it already launches sshd); only add labels.
buildah config \
  --label org.opencontainers.image.title=sshd \
  --label "org.opencontainers.image.description=Hardened sshd (pubkey-only, non-root user) on igk1972/sshd" \
  --label org.opencontainers.image.source=https://github.com/igk1972/builds \
  --label "org.opencontainers.image.created=${DATE}" \
  --label "org.opencontainers.image.base.name=${BASE_IMAGE}" \
  "$ctr"

PRIMARY="${IMAGE}:${IMAGE_TAG}"
buildah commit --format docker "$ctr" "$PRIMARY"
if [ "$PUSH" = "true" ]; then
  buildah push "$PRIMARY"
  echo ">> pushed: $PRIMARY"
else
  echo ">> PUSH=false: built ${PRIMARY} locally, not pushing"
fi
