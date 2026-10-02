# libsql-server-patched

Custom build of [libsql-server](https://github.com/tursodatabase/libsql) (`sqld`, Turso's
libSQL server) with the patches kept in
[igk1972/libsql-patched](https://github.com/igk1972/libsql-patched): upstream libsql at a pinned
commit plus fixes for bottomless (S3 backup) snapshot uploads, configurable S3 timeouts, and fixes
for the bundled sqlean extensions (crashes, memory safety, Unicode `text_like`). What each patch
changes is described in that repository's
[docs/patches.md](https://github.com/igk1972/libsql-patched/blob/main/docs/patches.md).

Published as a multi-arch (amd64 + arm64) image to `ghcr.io/igk1972/libsql-server-patched`.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile). It mirrors
upstream's `ghcr.io/tursodatabase/libsql-server`, on Debian **bookworm** instead of bullseye.
sqld compiles bundled C (SQLite, sqlean), so each architecture is built natively on its own
runner and the two images are joined into one manifest list.

## Image

- `ghcr.io/igk1972/libsql-server-patched:<tag>` — see Tags.
- `/bin/sqld` and `/bin/bottomless-cli`; `gosu`, `docker-wrapper.sh` and `docker-entrypoint.sh`
  from upstream. The entrypoint runs as root, creates and chowns `SQLD_DB_PATH`, then starts
  sqld as user `sqld` (uid/gid 666).
- Working directory and volume `/var/lib/sqld`; ports **8080** (HTTP/Hrana) and **5001** (gRPC).
- Upstream's environment variables apply to the default command `/bin/sqld` (`SQLD_NODE`,
  `SQLD_DB_PATH`, `SQLD_HTTP_LISTEN_ADDR`, …), which gets `--db-path`, `--http-listen-addr` and
  the gRPC flags added. A command starting with plain `sqld` runs with exactly the flags given.
- bash is included (e.g. for a `/dev/tcp` health check); there is no curl or wget.

```sh
docker run --rm ghcr.io/igk1972/libsql-server-patched:latest /bin/sqld --version
docker run -d -p 8080:8080 -v sqld-data:/var/lib/sqld ghcr.io/igk1972/libsql-server-patched:0.24.33-e4beaca
```

### Bottomless S3 settings added by the patches

All off unless set; values are positive integers.

| Variable | Unset |
|---|---|
| `LIBSQL_BOTTOMLESS_S3_CONNECT_TIMEOUT_SECS` | no connect timeout |
| `LIBSQL_BOTTOMLESS_S3_ATTEMPT_TIMEOUT_SECS` | no timeout per S3 request attempt |
| `LIBSQL_BOTTOMLESS_S3_STALLED_STREAM_GRACE_SECS` | stalled-stream protection disabled |
| `LIBSQL_BOTTOMLESS_SNAPSHOT_UPLOAD_ATTEMPTS` | 3 |

## Tags

| Tag | What it points at |
|---|---|
| `latest` | Most recent build |
| `<version>-<upstream sha>` (e.g. `0.24.33-e4beaca`) | libsql-server version and short upstream commit |
| `<libsql-patched sha>` (7 chars) | Exact patch set the image was built from |
| `<libsql-patched sha>-amd64` / `-arm64` | Per-architecture images the manifest list is made of |

Rebuilding with changed patches moves `latest` and `<version>-<upstream sha>`; pin the
libsql-patched sha tag for a fixed image.

## Building

CI: `.github/workflows/libsql-server-patched.yml` (`workflow_dispatch`; inputs `patches_ref`
— branch, tag or full sha of igk1972/libsql-patched, default `main` — and `push`). A `meta` job
resolves `patches_ref` to one commit, `image` builds on `ubuntu-24.04` and `ubuntu-24.04-arm`,
and `manifest` (only with `push`) joins and tags the result.

Locally (Linux only — buildah), for this machine's architecture:
`PUSH=false ./build.sh image` (`PATCHES_REF=<ref>` to pick the patch set).

## Licenses

The `build.sh`, CI workflow, and documentation in this repo are MIT-licensed.

The built images bundle upstream software that keeps its own license:

- [tursodatabase/libsql](https://github.com/tursodatabase/libsql) — MIT
- [nalgeon/sqlean](https://github.com/nalgeon/sqlean) (bundled by libsql) — MIT
- [tianon/gosu](https://github.com/tianon/gosu) — Apache-2.0
- Debian bookworm base image packages — their respective licenses
