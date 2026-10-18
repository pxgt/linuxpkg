# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/pxgt/linuxpkg/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pxgt/linuxpkg/releases/tag/v0.1.0
