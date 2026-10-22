# linuxpkg

[中文](README.md) · **English** · [Web page and signed repositories](https://pxgt.github.io/linuxpkg/)

linuxpkg is a pure-MoonBit toolkit (library and command line) that **builds, inspects, verifies, signs and publishes Linux
packages**. From one `linuxpkg.json` it writes Debian/Ubuntu/UOS/Kylin `.deb`, Fedora/openEuler/Anolis `.rpm`, Arch Linux
`.pkg.tar.zst` and Alpine `.apk` packages, makes apt, dnf, pacman and apk repositories, signs everything with OpenPGP, and
checks existing packages from any distribution. It shells out to nothing: tar, ar, cpio, the compression and the signatures
are MoonBit code, so it runs on the wasm, wasm-gc, js and native backends — on Windows, macOS, Linux and in a browser tab.
Output depends only on the input, so builds and even signatures are reproducible. Similar tools: nFPM (Go), fpm (Ruby),
cargo-deb (Rust).

## Try it

* In the browser, nothing uploaded: <https://pxgt.github.io/linuxpkg/> (inspect, verify and build packages).
* Install it from its own signed repository (Debian/Ubuntu, Fedora/openEuler, Arch, Alpine): the commands are on the page above.
* As a MoonBit library: `moon add Xpeng/linuxpkg`. Without installing: `moonx Xpeng/linuxpkg/cmd/main -- --help`.
* In CI: the GitHub Action `pxgt/linuxpkg` ([docs/github-action.md](docs/github-action.md)).

## What it does

| | deb | rpm | Arch | Alpine |
|---|---|---|---|---|
| Build, inspect, verify | ✅ | ✅ | ✅ | ✅ |
| Compression | gzip, xz, zstd, none | gzip, xz, zstd, none | zstd, xz, gzip, none | gzip |
| Package signature | via the repository | header signature (`rpm -K` OK) | detached `.sig` | `.SIGN.RSA256` stream |
| Repository | apt flat repo, `InRelease` | dnf repodata, `repomd.xml.asc` | `NAME.db` (as `repo-add`) | `APKINDEX.tar.gz` (as `apk index`) |
| Installs from a signed repository | ✅ apt `signed-by` | ✅ dnf `gpgcheck=1` | ✅ `SigLevel = Required` | ✅ no `--allow-untrusted` |

* One JSON configuration (field names follow nFPM): files, directories, symlinks, config files, owners, modes, dependencies,
  maintainer scripts, reproducible `mtime` / `SOURCE_DATE_EPOCH`.
* `linuxpkg init --moon` writes the configuration for the native executable of a MoonBit project (the architecture of an
  already built binary is used).
* nFPM configurations: `linuxpkg build nfpm.yaml` and `linuxpkg convert nfpm.yaml` read the file (overrides per packager,
  environment variables, version splitting, globs and trees, per-format sections); what is not supported is named in a warning. CI
  builds 29 nFPM acceptance configurations with the real nFPM and with linuxpkg and compares the packages
  ([docs/nfpm.md](docs/nfpm.md)).
* ELF detection (a small ELF reader in MoonBit, 32/64 bit, both byte orders): `build` refuses an arm64 program in an amd64 package
  (a warning for `all` packages, `--allow-arch-mismatch` to override), and `linuxpkg elf` / `inspect` show the CPU, static or
  dynamic linking, the interpreter and the needed libraries; the results match `readelf` for nine architectures.
* Signing is OpenPGP (RSA or Ed25519, no passphrase) written in MoonBit on top of the low-level packages of `justinwongcn/moonpgp`;
  signatures made by `gpg`, `rpmsign` and `abuild-sign` verify too.
* Reads and fully verifies real packages of Debian, Ubuntu, Fedora, openEuler, Arch and Alpine; every unpacking has a size limit.

## Command line

```sh
linuxpkg init --moon .                                   # configuration for a MoonBit project
linuxpkg build linuxpkg.json --out dist                  # deb, rpm, Arch and Alpine packages (--format, --compression)
linuxpkg build linuxpkg.json --sign-key release.key      # sign rpm, Arch and Alpine packages
linuxpkg repo dist --sign-key release.key                # apt, dnf, pacman and apk repositories, signed
linuxpkg inspect dist/hello_1.0.0-1_all.deb [--json]
linuxpkg verify dist/hello-1.0.0-1.noarch.rpm --keyring release.pub.asc   # exit status 2: damaged or wrongly signed
linuxpkg verify dist --keyring release.pub.asc           # check a repository directory
linuxpkg key apk-pub release.key --name myproject        # the .rsa.pub that Alpine users put in /etc/apk/keys/
```

Exit status: `0` success; `1` usage error, unreadable input or unsupported feature; `2` integrity or signature failure.
Documentation: [tutorial](docs/tutorial.md) · [configuration](docs/config.md) · [signing](docs/signing.md) ·
[repositories](docs/repository.md) · [formats](docs/formats.md) · [architecture](docs/architecture.md) ·
[verification](docs/verification.md) · [performance](docs/performance.md) · [development log](docs/devlog.md).

## How it is verified

The official tools are the judges (`tools/oracle/run.sh` on every push, `tools/oracle/containers.sh` in containers):

* packages written by linuxpkg are accepted by `dpkg`, `lintian`, `rpm -K -V`, `pacman -U -Qkk` and `apk add`/`apk audit`, and
  install and run in Debian 12, Ubuntu 24.04, Fedora 41, openEuler 24.03, Arch Linux and Alpine 3.20 containers;
* packages written by the official tools (and real distribution packages) are read and fully verified by linuxpkg;
* signatures: `gpgv`, `rpm -Kv`, `apt` (`signed-by`), `dnf` (`gpgcheck=1`, `repo_gpgcheck=1`), `pacman` (`Required`), `apk`
  (no `--allow-untrusted`) accept ours, refuse changed or unsigned ones; ours verify what `gpg`, `rpmsign`, `abuild-sign` made;
* repository databases equal the output of `repo-add` and `apk index`;
* the same input gives the same bytes on native, wasm, wasm-gc and js, and in the browser build.

## Quality

496 tests on every backend, 92.6 % line coverage of the core packages (CI floor 90 %), zero warnings, public interface files
checked in CI. Honest limits: the pure-MoonBit zstd encoder is much weaker than the official one (about 2.4 times the size of
gzip on text) and xz is 18–22 % behind `xz -6`; there is no bzip2; encrypted private keys are refused; Alpine signatures are RSA
only because apk only knows RSA. See [docs/formats.md](docs/formats.md) and [docs/performance.md](docs/performance.md).

## Credits and licence

Used by [moonthrift](https://github.com/pxgt/moonthrift), which builds its deb, rpm, Arch and Alpine packages with the GitHub Action
([workflow](https://github.com/pxgt/moonthrift/blob/main/.github/workflows/linux-packages.yml)).

Format knowledge from google/rpmpack (Apache-2.0), nFPM (MIT), the Debian, rpm.org, Arch and Alpine documentation; signing
building blocks from `justinwongcn/moonpgp`; compression from `moonbit-community/flate`, `Milky2018/zstd`, `lin2077-zeming/moonxz`
and `aurora0x27/lzma-mbt`. See [THIRD_PARTY.md](THIRD_PARTY.md). Apache-2.0, see [LICENSE](LICENSE).

The pull request to `justinwongcn/moonpgp` ([#2](https://github.com/justinwongcn/moonpgp/pull/2): support for flate 0.9.0 and a signature time that can be given, so that signatures are reproducible) was merged upstream on 2026-10-22.
