# caddy

Custom builds of [Caddy](https://caddyserver.com/), published to the single package
`ghcr.io/igk1972/caddy` as three **variants** selected by tag:

- **`l4`** — adds the [caddy-l4](https://github.com/mholt/caddy-l4) layer-4 (TCP/UDP) app.
- **`docker`** — adds [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy),
  which generates the Caddyfile from `caddy.*` labels on Docker/Swarm services.
- **`s3`** — no extra app; just Caddy plus the shared S3 modules below.

Every variant bundles two shared S3 modules:

- **[`certmagic-s3`](https://github.com/igk1972/certmagic-s3)** — replaces Caddy's default
  filesystem certificate storage with an S3-backed one (ACME account, certs, challenge
  tokens, distributed locks live in a shared bucket).
- **[`caddy-fs-s3`](https://github.com/sagikazarmark/caddy-fs-s3)** — an S3-backed `caddy.fs`
  filesystem, so `file_server` / `templates` can serve straight from a bucket.

`build.sh` assembles the images with **explicit buildah commands** (no Dockerfile):
`certmagic-s3` is a private fork not in the Caddy module registry, so binaries are compiled
with `xcaddy` (Go cross-compiles natively on amd64, so `linux/amd64` + `linux/arm64` build
on one runner without QEMU).

## Images

```sh
docker run --rm ghcr.io/igk1972/caddy:l4 version
docker run --rm ghcr.io/igk1972/caddy:docker version
docker run --rm ghcr.io/igk1972/caddy:s3 version
```

- Entrypoint `caddy` for all. `l4` and `s3` default to `run` with the standard Caddyfile
  (`/etc/caddy/Caddyfile`); `docker` defaults to `docker-proxy`. Pass any subcommand as args,
  e.g. `docker run ghcr.io/igk1972/caddy:l4 version`.

## The `docker` variant: HA reverse proxy on Docker Swarm

A fleet of identical `docker` replicas can serve as a highly-available reverse proxy. Stock
Caddy already auto-issues TLS for every hostname it routes, but only as a single instance.
The moment you want **multiple Caddy replicas across a Swarm**, three problems appear, and
`caddy-docker-proxy` + `certmagic-s3` solve all of them.

### 1. Service discovery without a leader

Each Caddy replica has to know about every Swarm service, not just the containers on its own
node. `caddy-docker-proxy` watches the Docker API (typically a TCP-exposed socket proxy on a
manager) and rebuilds the Caddyfile in-memory whenever services come and go. **Every replica
generates the same config independently** — no controller/follower split, no admin-API push
between replicas. Scaling is just `docker service scale caddy=N`.

### 2. Certificate coordination

If N replicas independently tried to issue a cert for the same hostname, you'd get duplicate
orders, ACME rate-limit pain, and divergent state. `certmagic-s3` gives every replica the
same backing store and a distributed lock: whichever replica wins the S3 lock runs the ACME
flow, writes cert + key + account to S3, and releases the lock; all others pick up the cert
from S3 on the next refresh. There's always exactly one issuance in flight per hostname.

### 3. HTTP-01 challenge response from any replica

During HTTP-01 validation, Let's Encrypt GETs `http://example.com/.well-known/acme-challenge/<token>`.
With N replicas behind round-robin DNS or a host-mode port, the request can land on any of
them. `certmagic-s3` writes the challenge token into S3 **before** telling LE to validate, so
any replica can read it back and respond. No "issuer node" pinning, no synchronized in-memory
state.

### Operational consequence

A traditional HA-Caddy-on-Swarm setup needs a pinned "ACME node", a cert-sync sidecar, and
internal routing so HTTP-01 challenges reach the issuer. With this image, **none of that
exists**. The full stack is a global `caddy` service plus a socket proxy on managers. Every
replica is identical and stateless beyond the shared S3 bucket; node death is uneventful —
Swarm reschedules, the new container reads state from S3, joins the rotation.

### Usage

Run it on a Swarm manager (or a worker that can reach a manager's Docker socket via a TCP
proxy) with credentials for the S3 bucket and the base Caddyfile mounted at
`/etc/caddy/Caddyfile`:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v ./Caddyfile:/etc/caddy/Caddyfile:ro \
  -e CADDY_DOCKER_CADDYFILE_PATH=/etc/caddy/Caddyfile \
  -e ACME_EMAIL=admin@example.com \
  -e S3_HOST=s3.eu-west-1.amazonaws.com \
  -e S3_BUCKET=my-bucket \
  -e S3_PREFIX=caddy \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  ghcr.io/igk1972/caddy:docker
```

Minimal `Caddyfile` to wire up the S3 storage adapter:

```caddyfile
{
  email {$ACME_EMAIL}
  storage s3 {
    host {$S3_HOST}
    bucket {$S3_BUCKET}
    prefix {$S3_PREFIX}
    access_id {$AWS_ACCESS_KEY_ID}
    secret_key {$AWS_SECRET_ACCESS_KEY}
  }
}
```

Apps in the swarm declare routing with two labels:

```yaml
labels:
  caddy: myapp.example.com
  caddy.reverse_proxy: "{{upstreams 8080}}"
```

That's enough for auto-HTTPS.

## The `l4` variant

`caddy-l4` adds a layer-4 (TCP/UDP) proxy app — routing raw connections by SNI/ALPN/protocol
before TLS termination, in front of or alongside the HTTP server. See the
[caddy-l4 docs](https://github.com/mholt/caddy-l4). The bundled `certmagic-s3` / `caddy-fs-s3`
modules are available here too (shared S3 storage/filesystem).

## The `s3` variant

Plain Caddy with just the shared `certmagic-s3` / `caddy-fs-s3` modules and no extra app —
for when you want S3-backed certificate storage and/or an S3 filesystem without `caddy-l4` or
`caddy-docker-proxy`. Wire up the storage adapter with the same `Caddyfile` block shown above.

## Tags

All tags live under `ghcr.io/igk1972/caddy`; the trailing `-<variant>` (`l4` / `docker` / `s3`)
marks the variant:

| Tag | What it points at |
|---|---|
| `l4` / `docker` / `s3` | Most recent build of that variant |
| `2.11-<variant>` | Latest patch of that Caddy minor, that variant |
| `2.11.4-<variant>` | Specific Caddy patch version, that variant |

Pin to a `<major.minor>-<variant>` tag in production; the bare `l4` / `docker` / `s3` tag is
fine for sandboxes.

## Building

The images are assembled with **explicit buildah commands** (no Dockerfile): `build.sh`
cross-compiles the Caddy binary for each arch with `xcaddy`, wraps each in the matching
`caddy:<version>` runtime, and pushes a multi-arch manifest list per variant.

CI: `.github/workflows/caddy.yml` (`workflow_dispatch`; inputs `variant`
(`all`/`l4`/`docker`/`s3`), `caddy_version`, `push`).
Locally (Linux only — buildah): `PUSH=false VARIANT=l4 ./build.sh` (or `docker`, `s3`, or `all`).

## Licenses

The `build.sh`, CI workflow, and documentation in this repo are MIT-licensed.

The built images bundle upstream binaries that keep their own licenses:

- [caddyserver/caddy](https://github.com/caddyserver/caddy) — Apache-2.0
- [mholt/caddy-l4](https://github.com/mholt/caddy-l4) — Apache-2.0
- [lucaslorentz/caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) — MIT
- [igk1972/certmagic-s3](https://github.com/igk1972/certmagic-s3) — Apache-2.0
- [sagikazarmark/caddy-fs-s3](https://github.com/sagikazarmark/caddy-fs-s3) — MIT
