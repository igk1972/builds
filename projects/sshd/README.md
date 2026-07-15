# sshd

Hardened OpenSSH server image: the [`igk1972/sshd`](https://hub.docker.com/r/igk1972/sshd)
base plus a locked-down `sshd_config` (pubkey-only, no root login, no passwords) and a
non-root `user` (uid/gid 1000). Published as a container image to `ghcr.io/igk1972/sshd`.

`build.sh` assembles the image with **explicit buildah commands** (no Dockerfile):
it layers the user and config onto the base image.

## Image

- `ghcr.io/igk1972/sshd:latest`.
- Authorized keys from `/etc/ssh/keys/authorized/<user>`; host keys from `/etc/ssh/keys/`.
- Pubkey auth only — `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 5`.

## Building

CI: `.github/workflows/sshd.yml` (`workflow_dispatch`; inputs `image_tag`, `base_image`).
The hardened config lives in [`sshd_config`](sshd_config).
Locally (Linux only — buildah): `PUSH=false ./build.sh`.
