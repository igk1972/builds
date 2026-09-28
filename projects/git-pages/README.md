# git-pages

Custom build of [igk1972/git-pages](https://github.com/igk1972/git-pages) — a fork of
[git-pages](https://codeberg.org/git-pages/git-pages) (a static site server for Git forges, a
GitHub Pages replacement) with `_headers`/`_redirects` fixes on top of upstream. Pure Go, no
CGO, published as a container image to `ghcr.io/igk1972/git-pages`.

This image is the **bare `git-pages` binary only** — unlike upstream's first-party container, it
does not bundle Caddy or supervisord. For TLS termination and S3-backed certificate storage, run
it alongside [`ghcr.io/igk1972/caddy:s3`](../caddy) as a second container instead of baking both
into one image.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile): it
cross-compiles the binary for each arch in one builder container (pure Go cross-compiles
natively on amd64, so `linux/amd64` + `linux/arm64` build on one runner without QEMU) and wraps
each in an Alpine runtime.

## Image

- `ghcr.io/igk1972/git-pages:<tag>` — plus `:sha-<commit>`.
- Runs as non-root user `pages` (uid 1000); working directory `/app`, site data under
  `/app/data` (bind-mount or persist as needed).
- Ports **3000** (pages) and **3002** (Prometheus metrics). The `caddy` listener from upstream's
  default config is disabled (`caddy = "-"` in [`config.toml`](config.toml)) since this image
  doesn't run Caddy.
- Config is [`config.toml`](config.toml) — only overrides the `[server]` bind addresses
  (upstream's default binds to `localhost`, unreachable from outside the container); everything
  else keeps upstream's built-in defaults (filesystem storage under `./data`, i.e. `/app/data`).
  To use S3 storage instead, mount a replacement `/app/config.toml` or set the `PAGES_STORAGE_*`
  environment variables (see [upstream's README](https://github.com/igk1972/git-pages#readme)).

```sh
docker run --rm -u 1000:1000 -v ./data:/app/data -p 3000:3000 ghcr.io/igk1972/git-pages:latest
```

Set `PAGES_INSECURE=1` to disable authentication for local testing (never in production — see
upstream's authorization docs).

## Building

CI: `.github/workflows/git-pages.yml` (`workflow_dispatch`; inputs `ref`, `image_tag`).
The default `ref` is `develop` — igk1972/git-pages's default branch.
Locally (Linux only — buildah): `PUSH=false ./build.sh`.
