# keys

Signing key for the Alpine apk repository.

- The **public** key (`*.rsa.pub`) is committed here — consumers trust it by placing it
  into `/etc/apk/keys/`. Its basename is embedded in every signature
  (`.SIGN.RSA.<name>.rsa.pub`), so the file name must not change.
- The **private** key (`*.rsa`) is NEVER committed — it lives only in the repository
  secret `ABUILD_PRIVKEY` (see `.gitignore`).

## One-time key generation

```sh
docker run --rm -e PACKAGER="Your Name <you@example.com>" \
  -v "$PWD/keys":/out alpine:3.22 sh -euc '
    apk add --no-cache abuild
    abuild-keygen -a -n                     # ~/.abuild/<name>.rsa[.pub]
    cp ~/.abuild/*.rsa.pub /out/            # public -> here (commit it)
    cp ~/.abuild/*.rsa     /out/PRIVATE.rsa # private -> secret, do NOT commit
  '
gh secret set ABUILD_PRIVKEY < keys/PRIVATE.rsa
rm keys/PRIVATE.rsa
```

## Rotation

Generate a new keypair, commit the new `.rsa.pub` (keep the old one published during
the transition so already-signed apks still verify), update the `ABUILD_PRIVKEY` secret,
and re-run the workflows (they rebuild and re-sign `APKINDEX`).
