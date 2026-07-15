# zerotier-one

Custom Alpine `apk` build of [ZeroTier One](https://www.zerotier.com/) — a
virtual-network / VPN daemon. Built from the aports-style recipe in [`alpine/`](alpine/)
on `alpine:edge` (C++/Rust: `make` + `cargo`, links OpenSSL 3).

Current version: **1.16.0-r0**.

## Install

From the apk repository:
```sh
wget -O /etc/apk/keys/igk1972-f66c23ba.rsa.pub \
     https://igk1972.github.io/builds/igk1972-f66c23ba.rsa.pub
apk add --repository https://igk1972.github.io/builds/community zerotier-one
```
Or pull the apk as an OCI artifact: `oras pull ghcr.io/igk1972/zerotier-one-apk:1.16.0-r0`.

## Packages

- `zerotier-one` — `zerotier-one`, `zerotier-cli`, `zerotier-idtool` binaries; autoloads
  the `tun` kernel module.
- `zerotier-one-openrc` — OpenRC service.
- `zerotier-one-doc` — man pages.

Because it dynamically links OpenSSL 3 / libstdc++, it's best consumed on `alpine:edge`
and is **not** shipped as a standalone binary — install the apk.
