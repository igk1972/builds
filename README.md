# builds

Personal monorepo of custom builds of upstream software. Artifacts are published to
three places:

- **GitHub Releases** — binary files;
- **GitHub Packages (ghcr)** — apks as OCI artifacts and container images;
- **GitHub Pages** — an installable, signed Alpine apk repository.

All builds are triggered manually (`workflow_dispatch`) and target **amd64**.

## Projects

| Project | What | Workflow | Artifacts |
|---|---|---|---|
| `nomad` | HashiCorp Nomad (Go) | `.github/workflows/nomad.yml` | apk (Pages + ghcr), optional binary in Release |
| `zerotier-one` | ZeroTier One (C++/Rust) | `.github/workflows/zerotier-one.yml` | apk (Pages + ghcr) |
| `mort` | mort — image processing server (Go) | `.github/workflows/mort.yml` | image `ghcr.io/igk1972/mort` (built with buildah) |

Recipes live in `projects/<project>/` (`alpine/APKBUILD` for apks, `build.sh` for the image).
The apk repository signing key lives in `keys/` (see `keys/README.md`).

## Installing apks from the repository

The Alpine repository is served on GitHub Pages (`https://igk1972.github.io/builds/community`):

```sh
# 1) trust the signing key (basename must match the file in keys/)
wget -O /etc/apk/keys/igk1972-f66c23ba.rsa.pub \
     https://igk1972.github.io/builds/igk1972-f66c23ba.rsa.pub

# 2) install a package
apk add --repository https://igk1972.github.io/builds/community nomad
# or add the repository permanently:
echo "https://igk1972.github.io/builds/community" >> /etc/apk/repositories
apk update && apk add nomad zerotier-one
```

## Pulling an apk as an OCI artifact (ghcr)

```sh
oras pull ghcr.io/igk1972/nomad-apk:1.11.1-r0     # -> nomad-1.11.1-r0.apk
```

## The mort image

```sh
docker run --rm ghcr.io/igk1972/mort:v0.37.0 -version
docker run -d -p 8080:8080 -p 8081:8081 ghcr.io/igk1972/mort:v0.37.0
```
