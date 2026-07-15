#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/mort from upstream aldor007/mort using explicit buildah
# commands (NO Dockerfile / NO buildah bud). amd64 only. Rootless in CI and locally.
set -euo pipefail

MORT_REF="${MORT_REF:-v0.37.0}"
IMAGE="${IMAGE:-ghcr.io/igk1972/mort}"
IMAGE_TAG="${IMAGE_TAG:-$MORT_REF}"
ALSO_TAG_LATEST="${ALSO_TAG_LATEST:-true}"
BASE_IMAGE="${BASE_IMAGE:-alpine:edge}"
PUSH="${PUSH:-true}"
MIME_TYPES_URL="${MIME_TYPES_URL:-https://raw.githubusercontent.com/apache/httpd/refs/heads/trunk/docs/conf/mime.types}"
WORKDIR="/workspace"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

SRC_DIR="$(mktemp -d)/mort"; STAGE_DIR="$(mktemp -d)"
cleanup() { buildah rm "${builder:-}" "${runtime:-}" 2>/dev/null || true; }
trap cleanup EXIT

# 1. Upstream source at pinned ref (branch/tag; fallback fetch-by-sha)
if ! git clone --depth 1 --branch "$MORT_REF" https://github.com/aldor007/mort.git "$SRC_DIR" 2>/dev/null; then
  git init "$SRC_DIR"; git -C "$SRC_DIR" remote add origin https://github.com/aldor007/mort.git
  git -C "$SRC_DIR" fetch --depth 1 origin "$MORT_REF"; git -C "$SRC_DIR" checkout --detach FETCH_HEAD
fi
MORT_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
MORT_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 2. Builder
builder="$(buildah from "$BASE_IMAGE")"
buildah run "$builder" -- apk add --no-cache go build-base pkgconfig git curl vips-dev brotli-dev
buildah config --workingdir "$WORKDIR" "$builder"
buildah copy "$builder" "$SRC_DIR/go.mod" "$WORKDIR/go.mod"
buildah copy "$builder" "$SRC_DIR/go.sum" "$WORKDIR/go.sum"
buildah run  "$builder" -- go mod download
for d in cmd .godir configuration etc pkg; do
  buildah copy "$builder" "$SRC_DIR/$d" "$WORKDIR/$d"
done
LDFLAGS="-s -w -X main.version=${MORT_REF} -X main.commit=${MORT_COMMIT} -X main.date=${MORT_DATE}"
buildah run --env CGO_ENABLED=1 --env CGO_CFLAGS_ALLOW="-Xpreprocessor" --env LDFLAGS="$LDFLAGS" \
  "$builder" -- sh -eu -c '
    mkdir -p /go
    export CGO_CFLAGS="$(pkg-config --cflags libbrotlienc libbrotlidec)"
    export CGO_LDFLAGS="$(pkg-config --libs libbrotlienc libbrotlidec)"
    go build -ldflags="$LDFLAGS" -trimpath -o /go/mort ./cmd/mort/mort.go
  '
buildah run "$builder" -- curl -fsSL -o /etc/mime.types "$MIME_TYPES_URL"

# 3. Copy artifacts OUT of builder rootfs (rootless -> under buildah unshare)
export builder STAGE_DIR WORKDIR
buildah unshare -- bash -euo pipefail -c '
  mnt="$(buildah mount "$builder")"
  cp "$mnt/go/mort"                          "$STAGE_DIR/mort"
  cp "$mnt/etc/mime.types"                   "$STAGE_DIR/mime.types"
  cp "$mnt$WORKDIR/configuration/config.yml" "$STAGE_DIR/mort.yml"
  cp "$mnt$WORKDIR/configuration/parse.tengo" "$STAGE_DIR/parse.tengo"
  buildah unmount "$builder"
'

# 4. Runtime
runtime="$(buildah from "$BASE_IMAGE")"
buildah run "$runtime" -- sh -eu -c '
  apk add --no-cache vips brotli ca-certificates
  addgroup -g 1000 mort; adduser -D -H -u 1000 -G mort mort
  mkdir -p /etc/mort; chown -R mort:mort /etc/mort
'
buildah copy --chmod 0755 "$runtime" "$STAGE_DIR/mort"        /usr/local/bin/mort
buildah copy --chmod 0644 "$runtime" "$STAGE_DIR/mort.yml"    /etc/mort/mort.yml
buildah copy --chmod 0644 "$runtime" "$STAGE_DIR/parse.tengo" /etc/mort/parse.tengo
buildah copy --chmod 0644 "$runtime" "$STAGE_DIR/mime.types"  /etc/mime.types
buildah run "$runtime" -- /usr/local/bin/mort -version        # smoke test

# 5. Config (ENV/USER/EXPOSE/ENTRYPOINT/labels)
# NOTE: no HEALTHCHECK. 'buildah config --healthcheck' sets it on the working
# container but 'buildah commit' drops it from the image (verified on buildah
# 1.33 and 1.43). Persisting a healthcheck would require a Containerfile/buildah
# bud, which this build deliberately avoids — define it at the orchestrator
# (compose/k8s) or run 'mort -version' as a liveness probe instead.
buildah config \
  --env MORT_CONFIG_DIR=/etc/mort --user mort --port 8080 --port 8081 \
  --entrypoint '["/usr/local/bin/mort"]' --cmd '' \
  --label org.opencontainers.image.title=mort \
  --label "org.opencontainers.image.description=mort (alpine/musl, vips+brotli)" \
  --label org.opencontainers.image.source=https://github.com/igk1972/builds \
  --label "org.opencontainers.image.revision=${GITHUB_SHA:-local}" \
  --label "org.opencontainers.image.created=${MORT_DATE}" \
  --label "org.opencontainers.image.version=${MORT_REF}" \
  --label "org.opencontainers.image.url=https://github.com/aldor007/mort" \
  "$runtime"

# 6. Commit + tag + push
PRIMARY="${IMAGE}:${IMAGE_TAG}"; SHA_TAG="${IMAGE}:sha-${MORT_COMMIT:0:12}"
buildah commit --format docker "$runtime" "$PRIMARY"
buildah tag "$PRIMARY" "$SHA_TAG"
[ "$ALSO_TAG_LATEST" = "true" ] && buildah tag "$PRIMARY" "${IMAGE}:latest"
if [ "$PUSH" = "true" ]; then
  buildah push "$PRIMARY"; buildah push "$SHA_TAG"
  [ "$ALSO_TAG_LATEST" = "true" ] && buildah push "${IMAGE}:latest"
else
  echo ">> PUSH=false: built ${PRIMARY} locally, not pushing"
fi
