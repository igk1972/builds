# caddy-l4

Custom build of [Caddy](https://caddyserver.com/) with the
[caddy-l4](https://github.com/mholt/caddy-l4) layer-4 (TCP/UDP) app, published as a
container image to `ghcr.io/igk1972/caddy-l4`.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile):
it starts from the official `caddy:2-alpine` and replaces `/usr/bin/caddy` with a
caddy-l4-enabled binary from the Caddy download API, then `setcap cap_net_bind_service`.

## Image

- `ghcr.io/igk1972/caddy-l4:latest` — plus a `:v<caddy-version>` tag.
- Entrypoint `caddy`; inherits the base image's default `run` command and `/etc/caddy` layout.

```sh
docker run --rm ghcr.io/igk1972/caddy-l4:latest version
```

## Building

CI: `.github/workflows/caddy-l4.yml` (`workflow_dispatch`; inputs `image_tag`, `plugins`, `base_image`).
`plugins` takes space-separated Caddy module paths (default `github.com/mholt/caddy-l4`).
Locally (Linux only — buildah): `PUSH=false ./build.sh`.
