# nomad

Custom Alpine `apk` build of [HashiCorp Nomad](https://www.nomadproject.io/) — an
easy-to-use workload orchestrator. Built from the aports-style recipe in
[`alpine/`](alpine/) on `alpine:edge` (Nomad needs a recent Go toolchain), musl-linked.

Current version: **1.11.1-r0**. Ships a customized OpenRC service (`supervise-daemon`
supervisor, `healthcheck`/`reload` commands) in [`alpine/nomad.initd`](alpine/nomad.initd).

## Install

From the apk repository:
```sh
wget -O /etc/apk/keys/igk1972-f66c23ba.rsa.pub \
     https://igk1972.github.io/builds/igk1972-f66c23ba.rsa.pub
apk add --repository https://igk1972.github.io/builds/community nomad nomad-openrc
```
Or pull the apk as an OCI artifact: `oras pull ghcr.io/igk1972/nomad-apk:1.11.1-r0`.

## Packages

- `nomad` — the `/usr/sbin/nomad` binary (depends on `cni-plugins`).
- `nomad-openrc` — OpenRC service + `/etc/nomad.d/server.hcl` default config.

The binary is musl-linked (runs on Alpine); it can also be attached to a GitHub Release
by running the workflow with `release_binary: true`.
