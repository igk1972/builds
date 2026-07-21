#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/caddy in two variants using explicit buildah commands (NO
# Dockerfile), each published as a multi-arch (amd64+arm64) manifest. Rootless in CI/locally.
#
#   l4     — Caddy + the layer-4 (caddy-l4) app
#   docker — Caddy + caddy-docker-proxy (Caddyfile from Docker labels)
#
# Both variants also bundle the shared S3 modules: certmagic-s3 (ACME storage) and
# caddy-fs-s3 (S3-backed filesystem). certmagic-s3 is a private fork, not in the Caddy
# module registry, so binaries are compiled with xcaddy (not the Caddy download API).
# xcaddy/Go cross-compile natively on amd64, so both arches build on one runner without QEMU.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/igk1972/caddy}"
VARIANT="${VARIANT:-all}"                                      # l4 | docker | all
CADDY_VERSION="${CADDY_VERSION:-2.11}"
BUILDER_IMAGE="${BUILDER_IMAGE:-docker.io/library/caddy:${CADDY_VERSION}-builder}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-docker.io/library/caddy:${CADDY_VERSION}}"
SHARED_PLUGINS="${SHARED_PLUGINS:-github.com/igk1972/certmagic-s3 github.com/sagikazarmark/caddy-fs-s3}"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"
PUSH="${PUSH:-true}"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

case "$VARIANT" in
  all)          VARIANTS="l4 docker s3" ;;
  l4|docker|s3) VARIANTS="$VARIANT" ;;
  *) echo "unknown VARIANT: $VARIANT (want l4|docker|s3|all)" >&2; exit 1 ;;
esac

# The defining module (s3 has none — only the shared S3 modules), default CMD, and
# description for each variant.
variant_plugin() { case "$1" in
  l4)     echo "github.com/mholt/caddy-l4" ;;
  docker) echo "github.com/lucaslorentz/caddy-docker-proxy/v2" ;;
  s3)     echo "" ;;
esac ; }
variant_cmd() { case "$1" in                                  # args-only CMD (entrypoint is caddy)
  l4|s3)  echo '["run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"]' ;;
  docker) echo '["docker-proxy"]' ;;
esac ; }
variant_desc() { case "$1" in
  l4)     echo "Caddy with the layer-4 (caddy-l4) app + certmagic-s3 storage + caddy-fs-s3 filesystem" ;;
  docker) echo "Caddy with caddy-docker-proxy + certmagic-s3 storage + caddy-fs-s3 filesystem" ;;
  s3)     echo "Caddy with certmagic-s3 storage + caddy-fs-s3 filesystem (no extra app)" ;;
esac ; }

DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Cross-compile the binary for every (variant, platform) in one native builder container.
#    --volume writes each binary straight to the host, so no buildah mount/unshare is needed.
bctr="$(buildah from "$BUILDER_IMAGE")"
for v in $VARIANTS; do
  WITH=()
  for p in $(variant_plugin "$v") $SHARED_PLUGINS; do WITH+=(--with "$p"); done
  for pf in $PLATFORMS; do
    arch="${pf#linux/}"
    echo ">> building caddy:$v for $pf"
    buildah run \
      --volume "$WORK:/out" \
      --env GOOS=linux --env GOARCH="$arch" --env CGO_ENABLED=0 \
      "$bctr" -- xcaddy build --output "/out/caddy-$v-$arch" "${WITH[@]}"
  done
done
buildah rm "$bctr"

# 2. Derive the exact Caddy version for tagging from any amd64 binary (runs natively here).
first_variant="${VARIANTS%% *}"
if [ -x "$WORK/caddy-${first_variant}-amd64" ]; then
  CADDY_FULL="$("$WORK/caddy-${first_variant}-amd64" version | head -1 | awk '{print $1}' | sed 's/^v//')"
else
  CADDY_FULL="$CADDY_VERSION"
fi

# 3. Assemble a multi-arch manifest per variant and push its tags (<variant>, <minor>-<variant>,
#    <patch>-<variant>).
for v in $VARIANTS; do
  MANIFEST="${IMAGE}:${CADDY_FULL}-${v}"
  vcmd="$(variant_cmd "$v")"
  buildah manifest rm "$MANIFEST" 2>/dev/null || true
  buildah manifest create "$MANIFEST"
  for pf in $PLATFORMS; do
    arch="${pf#linux/}"
    ctr="$(buildah from --arch "$arch" "$RUNTIME_IMAGE")"
    buildah copy --chmod 0755 "$ctr" "$WORK/caddy-$v-$arch" /usr/bin/caddy
    # The base image ships an empty entrypoint and a CMD that already starts with "caddy"
    # (["caddy","run",...]); pin entrypoint=caddy and give each variant its own args-only CMD.
    buildah config \
      --entrypoint '["caddy"]' \
      --cmd "$vcmd" \
      --label "org.opencontainers.image.title=caddy-$v" \
      --label "org.opencontainers.image.description=$(variant_desc "$v")" \
      --label org.opencontainers.image.source=https://github.com/igk1972/builds \
      --label "org.opencontainers.image.version=${CADDY_FULL}" \
      --label "org.opencontainers.image.created=${DATE}" \
      "$ctr"
    buildah commit --format docker --manifest "$MANIFEST" "$ctr"
    buildah rm "$ctr"
  done

  TAGS="${v} ${CADDY_VERSION}-${v} ${CADDY_FULL}-${v}"
  if [ "$PUSH" = "true" ]; then
    for t in $TAGS; do
      buildah manifest push --all "$MANIFEST" "docker://${IMAGE}:${t}"
      echo ">> pushed: ${IMAGE}:${t}"
    done
  else
    echo ">> PUSH=false: built manifest ${MANIFEST} locally (tags: ${TAGS}), not pushing"
  fi
done
