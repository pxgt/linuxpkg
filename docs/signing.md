# Signing

linuxpkg signs with OpenPGP (RFC 4880) and does not need `gpg` for it. The `sign` package is built on the low-level
packages of [`justinwongcn/moonpgp`](https://mooncakes.io/docs/justinwongcn/moonpgp) (packets, RSA, Ed25519, armor);
the signatures themselves are assembled in linuxpkg so that the signature time is a parameter.

## What gets signed, and how a user checks it

| You build | Signature | Written as | A user checks it with |
|---|---|---|---|
| apt repository (`repo --sign-key`) | `Release` | `InRelease` (cleartext), `Release.gpg` (detached) | apt: `deb [signed-by=KEY] ...` |
| dnf repository (`repo --sign-key`) | `repodata/repomd.xml` | `repodata/repomd.xml.asc` | dnf: `repo_gpgcheck=1`, `gpgkey=KEY` |
| rpm package (`build --sign-key`) | the main header (the digest of the payload is inside it) | tag 268 (RSA) or 267 (Ed25519) of the signature header | `rpm -K`, dnf: `gpgcheck=1` |
| Arch package (`build --sign-key`) | the whole package file | `<package>.sig` next to it | pacman: `SigLevel = Required` |
| Debian package | not signed one by one | the repository's `Release` carries the trust | apt, through `InRelease` |

Debian packages follow the Debian way: `dpkg` itself does not check a signature, apt checks the signed `Release` file,
which holds the hashes of the index files, which hold the hashes of the packages. `dpkg-sig` and `debsigs` signatures
are not used by the distributions and are not written.

## Keys

`--sign-key` takes an OpenPGP private key file, as `gpg --export-secret-keys` writes it (`--armor` or binary):

* version 4 keys, RSA (any size) or EdDSA with the ed25519 curve,
* **without a passphrase**. A protected key is refused with a clear message; in CI keep the key in a secret and decrypt
  it in the job, or use a key made only for signing packages.

The configuration can name the key instead of the command line: `"sign_key": "keys/release.asc"` (relative to the
configuration file); `--sign-key` wins. The key is never printed, and linuxpkg only reads it from the path you give.
Do not commit a private key; use a CI secret.

## Reproducible signatures

RSA (PKCS#1 v1.5) and Ed25519 signatures contain no randomness. The signature time is the build time
(`SOURCE_DATE_EPOCH`, the `mtime` of the configuration, or the repository date), but never earlier than the creation
time of the key, because `gpgv`, `rpm` and `pacman` refuse a signature older than its key. So the same package, key and
time give the same bytes, on every backend (wasm-gc, wasm, js, native): the unit tests compare signatures with fixed
values.

## Checking

```sh
linuxpkg verify hello-1.0.0-1.noarch.rpm                 # reports "signed by key ..." without checking
linuxpkg verify hello-1.0.0-1.noarch.rpm --keyring pub.asc
linuxpkg verify hello-1.0.0-1-any.pkg.tar.zst --keyring pub.asc   # reads the .sig next to it
linuxpkg verify repo/ --keyring pub.asc                  # InRelease, Release.gpg, repomd.xml.asc
```

`--keyring` takes ASCII-armored or binary public keys (several keys are fine; a private key file works too, its public
half is used). With a keyring, a package that is unsigned, signed by another key, or changed after signing fails with
exit status 2. Without one, the signature is only reported and the exit status does not change.

## Verified against the real tools

* `gpgv` accepts the detached and cleartext signatures; `gpg`'s own signatures verify with linuxpkg.
* `rpm -Kv`: `Header V4 RSA/SHA256 Signature, key ID ...: OK` and `Header V4 EdDSA/SHA256 Signature ...: OK`;
  signatures made by `rpmsign --addsign` verify with `linuxpkg verify --keyring`.
* apt, dnf and pacman install from signed repositories and packages in Debian, Ubuntu, Fedora, openEuler and Arch
  containers, and refuse changed or unsigned ones (`tools/oracle/run.sh`, `tools/oracle/containers.sh`).

## Test keys

`testdata/sign/` holds throw-away keys for the tests (the names contain `test-only`, the private keys are public on
purpose and worthless). They are made by `tools/oracle/make_sign_fixtures.sh`.
