# libsql-server-patched

Custom build of [libsql-server](https://github.com/tursodatabase/libsql) (`sqld`, Turso's
libSQL server) with the patches kept in
[igk1972/libsql-patched](https://github.com/igk1972/libsql-patched): upstream libsql at a pinned
commit plus fixes for bottomless (S3 backup) snapshot uploads, configurable S3 timeouts, and fixes
for the bundled sqlean extensions (crashes, memory safety, Unicode `text_like`), with jemalloc and
its heap profiler as the allocator. What each patch changes is described in that repository's
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
- `jeprof` (from the jemalloc built into sqld) and binutils, to read sqld's heap profiles; sqld
  is built with line tables, so profiles resolve to functions, inlined ones included, and
  source lines.

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

### Heap profiling

sqld allocates through jemalloc, its C code (SQLite) included, with jemalloc's
`background_thread:true` built in (`MALLOC_CONF` adds to it). The profiler is built in too and
off until sqld starts with `prof:true` in `MALLOC_CONF`:

| Variable | Example | Effect |
|---|---|---|
| `MALLOC_CONF` | `prof:true,lg_prof_sample:17,prof_prefix:/var/lib/sqld/prof/jeprof` | sample one allocation per 2^17 bytes (128 KiB) allocated; profiles go to `<prof_prefix>.*.heap` |
| `LIBSQL_HEAP_PROFILE_INTERVAL_SECS` | `3600` | every N seconds: write a profile (with profiling on) and log jemalloc's counters |

`POST /profile/heap/dump` on the admin API writes a profile on demand and returns its path and
the counters. Profiles are read with the `jeprof` of the image that wrote them (same `/bin/sqld`):

```sh
podman run --rm -v sqld-data:/var/lib/sqld:ro --entrypoint jeprof ghcr.io/igk1972/libsql-server-patched:<sha> \
  --text /bin/sqld /var/lib/sqld/prof/jeprof.<time>.heap
# growth between two profiles, by call stack
podman run … --text --base=/var/lib/sqld/prof/jeprof.<earlier>.heap /bin/sqld /var/lib/sqld/prof/jeprof.<later>.heap
```

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
- [jemalloc](https://github.com/jemalloc/jemalloc) (built into sqld; `jeprof`) — BSD-2-Clause
- [tianon/gosu](https://github.com/tianon/gosu) — Apache-2.0
- Debian bookworm base image packages — their respective licenses
