# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `spec`: `PackageSpec` model, validation of names, versions, install paths, modes, owners and
  relations; architecture mapping between deb and rpm names; `linuxpkg.json` parsing
  (`Config::parse`, `Config::sources`, `Config::resolve`).
- `archive/tar`: deterministic ustar writer with PAX or GNU long names; reader for ustar, GNU and
  PAX archives (checksum verification, offset-carrying errors).
- `archive/ar`: Debian-style ar writer and a reader that also understands GNU and BSD names.
- `deb`: `build`, `read`, `verify` and `to_json`; control, md5sums, conffiles and maintainer scripts;
  reading of packages written by `dpkg-deb`.
- `cmd/main`: `build` (deb), `init`, `inspect` (text and `--json`), `verify`, `--version`, `--help`.
- `examples/hello` and `tools/oracle` (checks against `dpkg-deb`, `dpkg`, `lintian`, GNU `tar`).
- CI: verify job on wasm, wasm-gc, js and native; oracle job using the official packaging tools.

### Notes

- deb data archives use GNU `L`/`K` long names: the extractor in `dpkg` 1.21 rejects PAX headers.
