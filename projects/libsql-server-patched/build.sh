#!/usr/bin/env bash
# Assemble ghcr.io/igk1972/libsql-server-patched — sqld and bottomless-cli built from upstream
# tursodatabase/libsql at the commit pinned in igk1972/libsql-patched, with that repo's patches
# applied — using explicit buildah commands (NO Dockerfile). The image mirrors upstream's
# ghcr.io/tursodatabase/libsql-server (gosu, docker-wrapper.sh/docker-entrypoint.sh, uid/gid 666,
# ports 8080/5001, volume /var/lib/sqld) on Debian bookworm instead of bullseye.
#
# sqld compiles bundled C (SQLite, sqlean) and is built natively on one runner per architecture;
# the per-arch images are then joined into one manifest list:
#
#   build.sh meta      print the libsql-patched commit PATCHES_REF resolves to and the version
#   build.sh image     build <patches-sha>-<arch> for this machine's architecture (and push it)
#   build.sh manifest  join the <patches-sha>-<arch> images and push the final tags:
#                      <libsql-server version>-<upstream sha> (e.g. 0.24.33-e4beaca), latest,
#                      <patches-sha>
#
# Rootless in CI and locally (Linux only).
set -euo pipefail

PATCHES_REPO="${PATCHES_REPO:-https://github.com/igk1972/libsql-patched.git}"
PATCHES_REF="${PATCHES_REF:-main}" # branch, tag or full commit sha
IMAGE="${IMAGE:-ghcr.io/igk1972/libsql-server-patched}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-docker.io/library/debian:bookworm-slim}"
GOSU_VERSION="${GOSU_VERSION:-1.17}"
ARCHES="${ARCHES:-amd64 arm64}"
PUSH="${PUSH:-true}"
export STORAGE_DRIVER="${STORAGE_DRIVER:-overlay}"
export BUILDAH_ISOLATION="${BUILDAH_ISOLATION:-chroot}"
export BUILDAH_FORMAT=docker

WORK="$(mktemp -d)"
ctrs=()
cleanup() {
  for c in ${ctrs[@]+"${ctrs[@]}"}; do buildah rm "$c" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# fetch_at <dir> <repo> <ref> [fetch args]: shallow fetch of one ref (branch, tag or full sha).
fetch_at() {
  local dir="$1" repo="$2" ref="$3"
  shift 3
  git init -q "$dir"
  git -C "$dir" remote add origin "$repo"
  git -C "$dir" fetch -q --depth 1 "$@" origin "$ref"
}

# pin <name>: a value from libsql-patched's mise.toml [env].
pin() {
  local value
  value="$(sed -n "s/^$1 *= *\"\(.*\)\"\$/\1/p" "$WORK/patched/mise.toml")"
  [ -n "$value" ] || { echo "$1 not found in libsql-patched/mise.toml" >&2; exit 1; }
  echo "$value"
}

resolve() {
  fetch_at "$WORK/patched" "$PATCHES_REPO" "$PATCHES_REF"
  git -C "$WORK/patched" checkout -q --detach FETCH_HEAD
  PATCHES_SHA="$(git -C "$WORK/patched" rev-parse HEAD)"
  LIBSQL_REPO="$(pin LIBSQL_REPO)"
  LIBSQL_REF="$(pin LIBSQL_REF)"
}

# <libsql-server version>-<short upstream sha>, read without checking out the upstream tree.
version_tag() {
  local version
  fetch_at "$WORK/libsql-meta" "$LIBSQL_REPO" "$LIBSQL_REF" --filter=blob:none
  version="$(git -C "$WORK/libsql-meta" show FETCH_HEAD:libsql-server/Cargo.toml |
    sed -n 's/^version *= *"\(.*\)"$/\1/p' | head -1)"
  echo "${version}-${LIBSQL_REF:0:7}"
}

cmd_meta() {
  resolve
  echo "patches_sha=$PATCHES_SHA"
  echo "version=$(version_tag)"
}

cmd_image() {
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac

  # 1. Upstream source at the pin, patched by libsql-patched's own setup task (the same commits
  #    as a local `mise run setup:sources`, so `sqld --version` reports the same sha).
  resolve
  local src="$WORK/libsql" out="$WORK/out"
  mkdir -p "$out"
  MISE_PROJECT_ROOT="$WORK/patched" SRC_DIR="$src" LIBSQL_REPO="$LIBSQL_REPO" LIBSQL_REF="$LIBSQL_REF" \
    bash "$WORK/patched/mise/tasks/setup/sources.sh"
  local version channel builder_image
  version="$(sed -n 's/^version *= *"\(.*\)"$/\1/p' "$src/libsql-server/Cargo.toml" | head -1)-${LIBSQL_REF:0:7}"
  channel="$(sed -n 's/^channel *= *"\(.*\)"$/\1/p' "$src/rust-toolchain.toml")"
  builder_image="${BUILDER_IMAGE:-docker.io/library/rust:${channel}-slim-bookworm}"
  echo ">> building libsql-server-patched $version (libsql-patched ${PATCHES_SHA:0:7}) for linux/$arch"

  # 2. Builder: the Rust toolchain pinned by upstream plus the build dependencies of upstream's
  #    Dockerfile. The source tree is mounted, so the binaries land on the host.
  local bctr
  bctr="$(buildah from "$builder_image")"
  ctrs+=("$bctr")
  buildah run --env DEBIAN_FRONTEND=noninteractive "$bctr" -- sh -eu -c '
    apt-get update
    apt-get install -y libclang-dev clang build-essential tcl protobuf-compiler file \
      libssl-dev pkg-config git cmake
    git config --global --add safe.directory "*"
  '
  # Two cargo invocations, as in upstream's Dockerfile: cargo unifies features across everything
  # built in one invocation, and bottomless-cli's dependency features must not leak into sqld.
  buildah run --volume "$src:/src" --volume "$out:/out" "$bctr" -- sh -eu -c '
    cd /src
    cargo build --locked --release -p libsql-server
    cargo build --locked --release -p bottomless-cli
    cp target/release/sqld target/release/bottomless-cli /etc/ssl/certs/ca-certificates.crt /out/
  '

  # 3. gosu, installed as upstream's Dockerfile does (release binary, signature checked).
  local gctr
  gctr="$(buildah from "$RUNTIME_IMAGE")"
  ctrs+=("$gctr")
  # shellcheck disable=SC2016 # expanded by bash inside the container
  buildah run --volume "$out:/out" --env GOSU_VERSION="$GOSU_VERSION" \
    --env DEBIAN_FRONTEND=noninteractive "$gctr" -- bash -eu -c '
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates gnupg wget
    dpkgArch="$(dpkg --print-architecture | awk -F- "{ print \$NF }")"
    wget -qO /out/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"
    wget -qO /tmp/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"
    export GNUPGHOME="$(mktemp -d)"
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4
    gpg --batch --verify /tmp/gosu.asc /out/gosu
    chmod +x /out/gosu
    /out/gosu --version
    /out/gosu nobody true
  '

  # 4. Runtime
  local rctr date
  date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  rctr="$(buildah from "$RUNTIME_IMAGE")"
  ctrs+=("$rctr")
  buildah run "$rctr" -- sh -eu -c '
    groupadd --system --gid 666 sqld
    useradd --system --uid 666 --gid 666 --home-dir /var/lib/sqld --create-home \
      --shell /usr/sbin/nologin sqld
    chmod 0755 /var/lib/sqld
  '
  buildah copy --chmod 0755 "$rctr" "$src/docker-entrypoint.sh" "$src/docker-wrapper.sh" /usr/local/bin/
  buildah copy --chmod 0755 "$rctr" "$out/gosu" /usr/local/bin/gosu
  buildah copy --chmod 0644 "$rctr" "$out/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt
  buildah copy --chmod 0755 "$rctr" "$out/sqld" /bin/sqld
  buildah copy --chmod 0755 "$rctr" "$out/bottomless-cli" /bin/bottomless-cli
  buildah run "$rctr" -- /bin/sqld --version # smoke test
  buildah config \
    --port 5001 --port 8080 --volume /var/lib/sqld --workingdir /var/lib/sqld --user root \
    --entrypoint '["/usr/local/bin/docker-wrapper.sh"]' --cmd '["/bin/sqld"]' \
    --label org.opencontainers.image.title=libsql-server-patched \
    --label "org.opencontainers.image.description=libsql-server (sqld) with the patches of igk1972/libsql-patched" \
    --label org.opencontainers.image.source=https://github.com/igk1972/builds \
    --label org.opencontainers.image.url=https://github.com/igk1972/libsql-patched \
    --label "org.opencontainers.image.revision=${PATCHES_SHA}" \
    --label "org.opencontainers.image.version=${version}" \
    --label "org.opencontainers.image.created=${date}" \
    --label "org.opencontainers.image.base.name=${RUNTIME_IMAGE}" \
    "$rctr"

  # 5. Commit + push the per-arch image
  local arch_tag="${IMAGE}:${PATCHES_SHA:0:7}-${arch}"
  buildah commit --format docker "$rctr" "$arch_tag"
  if [ "$PUSH" = "true" ]; then
    buildah push "$arch_tag"
    echo ">> pushed: $arch_tag"
  else
    echo ">> PUSH=false: built $arch_tag locally, not pushing"
  fi
}

cmd_manifest() {
  resolve
  local short="${PATCHES_SHA:0:7}" version list
  version="$(version_tag)"
  list="${IMAGE}:${short}"
  buildah manifest rm "$list" >/dev/null 2>&1 || true
  buildah manifest create "$list"
  for arch in $ARCHES; do
    buildah manifest add "$list" "docker://${IMAGE}:${short}-${arch}"
  done
  for tag in "$version" latest "$short"; do
    if [ "$PUSH" = "true" ]; then
      buildah manifest push --all "$list" "docker://${IMAGE}:${tag}"
      echo ">> pushed: ${IMAGE}:${tag}"
    else
      echo ">> PUSH=false: not pushing ${IMAGE}:${tag}"
    fi
  done
}

case "${1:-}" in
  meta) cmd_meta ;;
  image) cmd_image ;;
  manifest) cmd_manifest ;;
  *) echo "usage: $0 meta|image|manifest" >&2; exit 1 ;;
esac
