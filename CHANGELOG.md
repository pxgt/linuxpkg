# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `compress` package: one place for gzip, xz, zstd, `.lzma` (read-only) and uncompressed streams —
  `compress`, `decompress` with a size limit, `detect` by signature, `Compression::parse`/`name`/`extension`.
  xz and `.lzma` come from `aurora0x27/lzma-mbt`, zstd from `Milky2018/zstd`.
- deb: `build(spec, compression~)` writes `control.tar`/`data.tar` with `.gz`, `.xz`, `.zst` or no suffix; `read`
  accepts gzip, xz, zstd, lzma and uncompressed members, in any combination.
- rpm: `build(spec, compression~)` writes gzip, xz, zstd or uncompressed payloads, with
  `rpmlib(PayloadIsXz)` / `rpmlib(PayloadIsZstd)` in the requirements; `read`/`verify` unpack gzip, xz, zstd,
  lzma and uncompressed payloads, so packages from Debian, Ubuntu, Fedora and openEuler are verified in full.
- Configuration: `compression` (package-wide) and `deb` / `rpm` objects with their own `compression`;
  command line: `build --compression none|gzip|xz|zstd` (`-z`).
- Bounded unpacking for xz and zstd: the unpacked size is measured from the block / frame headers before
  decoding, on top of the existing gzip limit (default 1 GiB).
- Tests: real xz / zstd / lzma / gzip streams from the reference tools, bombs, truncations and bit flips for every
  compression, real `dpkg-deb -Zxz/-Zzstd` debs; the oracle script builds, installs and verifies every compression
  with `dpkg`, `rpm` and `rpm2cpio`; the container job installs every compression in Debian, Ubuntu, Fedora and
  openEuler and verifies the distributions' own `hello` / `tree` packages.

- `repo` package and `linuxpkg repo <dir> [--format deb|rpm|all]`: apt flat repository (`Packages`, `Packages.gz`,
  `Packages.xz`, `Release`) and dnf repodata (`repomd.xml`, primary, filelists, other) in createrepo's layout, with
  `check_apt` / `check_yum` to read them back; `docs/repository.md` also shows how to sign with an external gpg.

### Changed

- `Config` gained `compression`, `deb` and `rpm` fields; `PackageSpec` is unchanged.
- `verify` no longer reports xz and zstd packages as unsupported; only bzip2 stays unsupported.
- rpm payloads without a `PAYLOADCOMPRESSOR` tag (what rpmbuild writes for uncompressed payloads) are recognised
  from the payload itself.
- `internal/gunzip` was folded into `compress`.

### Known limits

- The xz and zstd encoders in the underlying libraries are weak: xz output is about as large as gzip, zstd output
  is about 2.4 times larger than gzip on text (see `docs/formats.md`). The default stays gzip.
- bzip2 is not supported (no pure-MoonBit implementation exists).

## [0.2.0] - 2026-10-18

### Added

- `docs/` (formats, verification, configuration reference), `CONTRIBUTING.md`, `SECURITY.md`.
- `tools/check_core_coverage.py` and a CI coverage floor of 80% (measured: 95.7%).
- Hostile-input tests for every reader; duplicate file names in an rpm header are reported by `verify`.

### Changed

- gzip payloads are unpacked through a streaming decoder with a hard output limit, so a gzip bomb is stopped
  while decoding instead of after allocation.
- The js backend of the CLI skips node and the script path in its arguments.

## [0.1.0] - 2026-10-18

First release.

### Added

- `spec`: `PackageSpec` model, validation of names, versions, install paths, modes, owners and
  relations; architecture mapping between deb and rpm names; `linuxpkg.json` parsing
  (`Config::parse`, `Config::sources`, `Config::resolve`).
- `archive/tar`: deterministic ustar writer with PAX or GNU long names; reader for ustar, GNU and
  PAX archives (checksum verification, offset-carrying errors).
- `archive/ar`: Debian-style ar writer and a reader that also understands GNU and BSD names.
- `deb`: `build`, `read`, `verify` and `to_json`; control, md5sums, conffiles and maintainer scripts;
  reading of packages written by `dpkg-deb`.
- `archive/cpio`: newc writer and reader.
- `rpm`: header encoding/decoding with immutable regions, `build` (lead, signature header with SHA-256, main
  header with file arrays, dependencies and scripts, gzip cpio payload with SHA-256 digests), `read`, `verify`
  (header, payload and per-file digests) and `to_json`; reading of rpmbuild packages with gzip, xz and zstd payloads.
- `cmd/main`: `build` (deb and rpm, `--format deb|rpm|all`), `init`, `inspect` (text and `--json`) and `verify` for both formats, `--version`, `--help`.
- `examples/hello` and `tools/oracle` (checks against `dpkg-deb`, `dpkg`, `lintian`, GNU `tar`).
- CI: verify job on wasm, wasm-gc, js and native; oracle job using the official packaging tools; containers job
  installing the packages in Debian 12, Ubuntu 24.04, Fedora 41 and openEuler 24.03 LTS.

### Notes

- deb data archives use GNU `L`/`K` long names: the extractor in `dpkg` 1.21 rejects PAX headers.

[Unreleased]: https://github.com/pxgt/linuxpkg/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/pxgt/linuxpkg/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/pxgt/linuxpkg/releases/tag/v0.1.0
