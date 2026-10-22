# GitHub Action

`pxgt/linuxpkg` is also a composite GitHub Action: it downloads the static linuxpkg binary of a release, checks it against
`SHA256SUMS`, builds your packages and, if you give it a key, signs them. No Docker, no `dpkg`, no `rpmbuild`; it runs on
Linux runners (x86_64 and arm64).

```yaml
- uses: actions/checkout@v5
- uses: pxgt/linuxpkg@v0.5.0
  with:
    config: linuxpkg.json        # default
    format: all                  # deb, rpm, arch, apk or all
    out: dist                    # default
    sign-key: ${{ secrets.PACKAGE_SIGNING_KEY }}   # optional, an armored OpenPGP private key without passphrase
    apk-key-name: myproject.rsa.pub                 # optional, name of the Alpine public key
```

| Input | Meaning |
|---|---|
| `config` | the `linuxpkg.json` to build (default `linuxpkg.json`) |
| `format` | `deb`, `rpm`, `arch`, `apk` or `all` (default) |
| `out` | output directory (default `dist`) |
| `compression` | `none`, `gzip`, `xz`, `zstd`; empty keeps the configuration |
| `sign-key` | private key that signs rpm, Arch and Alpine packages; pass a secret, it is written to a temporary file and removed |
| `apk-key-name` | file name of the Alpine public key (`myproject.rsa.pub`) |
| `version` | linuxpkg version to download; empty uses the tag after `@` |
| `binary-path` | use this binary instead of a download (for testing) |

Outputs: `files` (the files written, one per line) and `version`.

## From a MoonBit project to the four package managers

[`examples/github-action/release.yml`](../examples/github-action/release.yml) is a complete workflow: it builds a MoonBit
program as a static native binary, lets `linuxpkg init --moon` write the configuration, builds and signs the packages and
attaches them to the GitHub Release.

## How the action is tested

The CI of this repository runs the action with the binary it has just built (`binary-path`) and the test-only key, then
checks the signatures of the results with `linuxpkg verify --keyring` (job "GitHub Action (self test)").
