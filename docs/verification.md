# How to reproduce every verification

linuxpkg is checked against the official tools instead of only against itself.

## Unit tests

```sh
moon test --target wasm-gc     # also: js, wasm
moon test --target native      # Linux or WSL (Windows needs MSVC for native)
```

453 tests on every backend (property tests with a fixed-seed generator for tar, ar, cpio, rpm headers and compression; signature tests with golden values that make the four backends prove they write the same bytes), including fixed-byte expectations, archives written by GNU tar, GNU cpio, `dpkg-deb` and `rpmbuild`
(fixtures under `*/fixtures_test.mbt`), and hostile input: every truncation and every flipped byte of a valid
tar, ar, cpio, deb and rpm must produce a value or a typed error, never a crash.

## Coverage

```sh
python tools/check_core_coverage.py --minimum 90
```

Runs the instrumented tests and prints line coverage per core package; CI enforces the floor.

## Official tool checks (oracle)

```sh
sudo apt-get install -y lintian rpm rpm2cpio cpio     # dpkg-deb and dpkg come with Debian/Ubuntu
tools/oracle/run.sh                                     # builds the native CLI first
```

On WSL, where the project lives on the Windows file system, build somewhere else:
`TARGET_DIR=$HOME/lp_build tools/oracle/run.sh`.

The script checks, in order:

1. **deb → dpkg**: `dpkg-deb --info/--field/--contents/--extract/--control`, md5sums, `dpkg -i`, `dpkg --verify`,
   `dpkg -L/-s`, `dpkg -r` (config file kept), `dpkg -P` (config file removed); `lintian` is recorded, not fatal.
2. **rpm → rpm**: `rpm -K` (digests OK, header and payload SHA256), `-qp --qf`, `-qip`, `-qlp`, `-qlvp`, `-qcp`,
   `--scripts`, `--provides`, `--requires`, `rpm2cpio | cpio` with `cmp` against the sources, an install into a
   private `--root`, `rpm -V` without differences, `rpm -e`.
3. **Reverse**: our `inspect --json` and `verify` against a deb built by `dpkg-deb -Zgzip` and an rpm built by
   `rpmbuild` (`w9.gzdio`); a flipped payload byte and a forged file give exit status 2. Debs from
   `dpkg-deb -Zxz/-Zzstd/-Znone` and rpms from `rpmbuild` with `w2.xzdio`, `w19.zstdio` and `w.ufdio` are read and
   verified in full (exit 0).
4. **Relations**: depends/recommends/suggests/conflicts/replaces/provides/epoch in both formats against
   `dpkg-deb --field` and `rpm -qp --requires/--conflicts/--obsoletes/--provides/--recommends/--suggests`.
5. **Owners and modes** reach `dpkg-deb --contents` and `rpm -qlvp`.
6. **Self-hosting**: linuxpkg packages its own release binary (`examples/self`), the deb is installed and the
   installed `linuxpkg` rebuilds the hello deb byte for byte.
7. **Reproducibility**: repeated builds are identical; `SOURCE_DATE_EPOCH` controls the timestamps.
8. **Repositories**: `linuxpkg repo` on a directory of debs makes a flat apt repository: its `Packages` has the same
   fields and values as `apt-ftparchive packages .`, `apt-get update` accepts it and `apt-get install` resolves a
   dependency through it. For rpms, `filelists.xml` and `other.xml` are compared with `createrepo_c`, and `primary.xml`
   too (apart from createrepo_c condensing `libc.so.6(GLIBC_*)` requirements).
9. **Arch Linux**: `bsdtar` (libarchive, the reader behind pacman) lists, extracts and agrees with our `.MTREE` on every
   entry (type, mode, size, SHA-256, link) for each compression; `.PKGINFO` and `.INSTALL` are checked.
10. **Alpine**: Python's `tarfile` reads both segments of an `.apk`, `datahash` is the SHA-256 of the data stream and every
    `APK-TOOLS.checksum.SHA1` is right; with a static `apk` on the path, `apk add --allow-untrusted` installs the package in a
    private root without warnings and `apk audit --full` finds no differences.
11. **Compression**: the example is built with `--compression xz|zstd|none`; `dpkg-deb` lists, extracts and checks md5sums,
   `dpkg -i`, `dpkg --verify` and `dpkg -P` pass; `rpm -K` and `Payload SHA256 digest: OK`, the `rpmlib(PayloadIsXz)` /
   `rpmlib(PayloadIsZstd)` requirements in `rpm -qp --requires`, `rpm2cpio | cpio`, a private-root install and `rpm -V`
   pass. A configuration with `"compression": "xz"` and `"rpm": {"compression": "zstd"}` is checked too.

## Distribution containers

```sh
tools/oracle/containers.sh        # needs docker
```

Installs the deb in `debian:12` and `ubuntu:24.04` and the rpm (`rpm -ivh` and `dnf install`) in `fedora:41` and
`openeuler/openeuler:24.03-lts` (falling back to `rockylinux:9` if that image cannot be pulled), once for each of
gzip, xz, zstd and no compression. Inside each container it runs the program, checks the maintainer script marker,
runs `dpkg --verify` / `rpm -V`, removes the package and checks the removal.

In `archlinux:latest` it runs `pacman -U` on the hello package of every compression, runs the program and the
`.INSTALL` scripts, and checks `pacman -Q`, `-Qi`, `-Ql`, `-Qo`, `pacman -Qkk` (no altered files) and `pacman -R`. For the
reverse direction it downloads `which` and `tree` with `pacman -Sw` and builds a package with the real `makepkg`, then
compares `inspect --json` with `pacman -Qip` / `-Qlp` and runs `verify` (exit 0) on each.

In `alpine:3.20` it runs `apk add --allow-untrusted` on the hello apk (scripts included), checks the program, the
maintainer-script marker, `apk info -L` and `apk audit --full` for the package's files, and `apk del`; then it
fetches `tree` and `busybox-binsh` from Alpine's repository with `apk fetch` and compares `inspect --json` with
`apk info -qL`, and `verify` must exit 0.

It also builds a repository from a hello package and a package depending on it, and installs the dependent package
with the container's own tools: `apt-get install` in `debian:12` and `ubuntu:24.04` (with `[trusted=yes]`), and
`dnf install` in `fedora:41` and openEuler (with `gpgcheck=0`). The repository commands run twice must give
identical files.

It also reads **genuine distribution packages** with the distribution's own downloader and compares
`inspect --json` with `dpkg-deb` / `rpm -qp` (name, version, architecture, compression, file list), then runs `verify`
on them, which must exit 0: `apt-get download hello` in `debian:12` (xz) and `ubuntu:24.04` (zstd), `dnf download hello`
in `fedora:41` (zstd) and `dnf download tree` in openEuler (or Rocky Linux).

## Fixtures

```sh
tools/oracle/make_tar_fixtures.sh    # GNU tar: ustar, pax and gnu formats
tools/oracle/make_cpio_fixtures.sh   # GNU cpio
tools/oracle/make_deb_fixtures.sh    # dpkg-deb, gzip, xz and zstd
tools/oracle/make_rpm_fixtures.sh    # rpmbuild, gzip, xz and zstd
tools/oracle/make_sign_fixtures.sh   # throw-away OpenPGP test keys (testdata/sign/) and gpg's signatures over a fixed text
tools/oracle/make_compress_fixtures.sh   # xz (several checks, blocks, streams), lzma, zstd (levels, streaming), gzip
```

Each script rewrites the matching `fixtures_test.mbt` and must be run on Linux with the real tools.

## Signatures, repositories and the browser build

`tools/oracle/run.sh` also checks, with the real tools: `gpgv` on `InRelease`, `Release.gpg` and `repomd.xml.asc`; apt with
`signed-by` and a changed `Release` refused; `rpm -Kv` on signed rpm packages and `rpm -K` refusing a changed header;
`rpmsign`'s signature verified by `linuxpkg verify --keyring`; `gpgv` on Arch `.sig` files; apk-tools installing a signed
package from a key directory without `--allow-untrusted`, `openssl dgst -sha256 -verify` on the apk signature, an
abuild-style SHA-1 package; `APKINDEX.tar.gz` compared with `apk index`; and `tools/assemble_site.sh` building the four
signed repositories for two architectures. `tools/oracle/containers.sh` repeats the installs in the distribution
containers (apt `signed-by`, dnf `gpgcheck=1` and `repo_gpgcheck=1`, pacman `Required DatabaseRequired`, apk without
`--allow-untrusted`), compares the pacman databases with `repo-add` and the apk index with `apk index`, and checks that
changed or unsigned packages are refused. `tools/web_smoke.js` runs the browser build under Node and compares it with
the command line (same package bytes, same `inspect` JSON).

## CI

`.github/workflows/ci.yml` has four jobs: **verify** (fmt, interface drift, check with warnings denied, build and
test on wasm-gc, wasm, js and native, CLI packages identical across backends, coverage floor, `moon package`),
**oracle** (`tools/oracle/run.sh`), **containers** (`tools/oracle/containers.sh`) and **action** (the GitHub Action run on the binary just built).
`pages.yml` publishes the site and the signed repositories and installs linuxpkg from them over https in six containers;
`release.yml` builds the release files and installs them in containers.
