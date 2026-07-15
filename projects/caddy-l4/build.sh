#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/caddy-l4 from the official caddy:2-alpine image, replacing
# the stock caddy with a caddy-l4 (layer-4) enabled binary from the Caddy download API,
# using explicit buildah commands (NO Dockerfile). amd64 only. Rootless in CI and locally.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/igk1972/caddy-l4}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
BASE_IMAGE="${BASE_IMAGE:-caddy:2-alpine}"
PLUGINS="${PLUGINS:-github.com/mholt/caddy-l4}"   # space-separated Caddy module paths
PUSH="${PUSH:-true}"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

# Build the Caddy download URL (amd64) with each plugin as a url-encoded p= param.
Q="os=linux&arch=amd64"
for p in $PLUGINS; do
  enc=$(printf '%s' "$p" | sed 's|/|%2F|g')
  Q="$Q&p=$enc"
done
DL_URL="https://caddyserver.com/api/download?$Q"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ctr="$(buildah from "$BASE_IMAGE")"
cleanup() { buildah rm "$ctr" 2>/dev/null || true; }
trap cleanup EXIT

buildah run --env DL_URL="$DL_URL" "$ctr" -- sh -eu -c '
  apk add --no-cache --virtual .caddybuild curl libcap
  curl -fSL -o /usr/bin/caddy "$DL_URL"
  chmod a+x /usr/bin/caddy
  setcap cap_net_bind_service=+ep /usr/bin/caddy
  apk del .caddybuild
  caddy version
'
CADDY_VER="$(buildah run "$ctr" -- caddy version 2>/dev/null | head -1 | awk '{print $1}')"

# Keep the base image's default CMD (caddy run ...); only pin the entrypoint + labels.
buildah config \
  --entrypoint '["caddy"]' \
  --label org.opencontainers.image.title=caddy-l4 \
  --label "org.opencontainers.image.description=Caddy with the layer-4 (caddy-l4) plugin" \
  --label org.opencontainers.image.source=https://github.com/igk1972/builds \
  --label "org.opencontainers.image.version=${CADDY_VER}" \
  --label "org.opencontainers.image.created=${DATE}" \
  --label "org.opencontainers.image.url=https://github.com/mholt/caddy-l4" \
  "$ctr"

PRIMARY="${IMAGE}:${IMAGE_TAG}"
buildah commit --format docker "$ctr" "$PRIMARY"
[ -n "$CADDY_VER" ] && buildah tag "$PRIMARY" "${IMAGE}:${CADDY_VER}"
if [ "$PUSH" = "true" ]; then
  buildah push "$PRIMARY"
  [ -n "$CADDY_VER" ] && buildah push "${IMAGE}:${CADDY_VER}"
  echo ">> pushed: $PRIMARY ${CADDY_VER:+, ${IMAGE}:${CADDY_VER}}"
else
  echo ">> PUSH=false: built ${PRIMARY} locally, not pushing"
fi
