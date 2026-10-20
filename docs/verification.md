# How to reproduce every verification

linuxpkg is checked against the official tools instead of only against itself.

## Unit tests

```sh
moon test --target wasm-gc     # also: js, wasm
moon test --target native      # Linux or WSL (Windows needs MSVC for native)
```

179 tests, including fixed-byte expectations, archives written by GNU tar, GNU cpio, `dpkg-deb` and `rpmbuild`
(fixtures under `*/fixtures_test.mbt`), and hostile input: every truncation and every flipped byte of a valid
tar, ar, cpio, deb and rpm must produce a value or a typed error, never a crash.

## Coverage

```sh
python tools/check_core_coverage.py --minimum 80
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
8. **Compression**: the example is built with `--compression xz|zstd|none`; `dpkg-deb` lists, extracts and checks md5sums,
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
tools/oracle/make_compress_fixtures.sh   # xz (several checks, blocks, streams), lzma, zstd (levels, streaming), gzip
```

Each script rewrites the matching `fixtures_test.mbt` and must be run on Linux with the real tools.

## CI

`.github/workflows/ci.yml` has three jobs: **verify** (fmt, interface drift, check with warnings denied, build and
test on wasm-gc, wasm, js and native, CLI packages identical across backends, coverage floor, `moon package`),
**oracle** (`tools/oracle/run.sh`) and **containers** (`tools/oracle/containers.sh`).
