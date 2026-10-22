# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **nFPM configurations**: `linuxpkg build nfpm.yaml` and the new `linuxpkg convert nfpm.yaml [--format deb|rpm|apk|arch] [-o FILE]`
  read an nFPM file (a name ending in `.yaml` or `.yml`): `overrides` and `packager:` per format, environment variables (Go
  `os.Expand` rules), version/pre-release/metadata splitting like nFPM, `type` config flavours, dir, symlink, tree, globs, `file_info`,
  signature `key_file`, compression. Every unsupported field is named in a warning, unknown fields are errors. New package `nfpm`
  (`@nfpm.convert`), YAML by `moonbitstack/moonyaml`. CI builds 29 nFPM acceptance configurations with the real nFPM v2.48.0 and
  compares the packages; the explained differences are in `docs/nfpm.md`.
- **ELF architecture detection** (new package `elf`, no file system, all backends): `build` stops when an ELF file in `contents`
  is for another CPU than `arch` (`contents[0]: /usr/bin/hello is an ELF file for arm64, but the package architecture is
  amd64`), warns when an `all` package contains ELF files, and accepts `"allow_arch_mismatch": true` /
  `--allow-arch-mismatch`. `linuxpkg elf FILE [--json]` shows CPU, 32/64 bit, byte order, static or dynamic, interpreter,
  `DT_NEEDED`, `DT_SONAME`; `inspect` shows it under each ELF file and `inspect --json` has an `elf` object per file (`null` for
  other files); the web page shows it too. `init --moon` takes the architecture of an already built binary. Checked
  against `readelf` on nine architectures in CI.
- `Config.allow_arch_mismatch` (a new field), `Config::elf_warnings`.

### Fixed

- The home page navigation wraps on phone widths instead of cutting the last item; the stale compiled `site/linuxpkg-web.js` is no longer tracked (the Pages workflow builds it).
- Release workflow: the Alpine asset names now contain the architecture (`linuxpkg-<version>-r1.x86_64.apk`,
  `...aarch64.apk`); before, both builds wrote the same name and one asset of v0.4.0 was damaged. The workflow can be
  started by hand for an existing tag to replace the assets of that release.
- The Pages workflow no longer runs for release events (the `github-pages` environment only accepts `main`).

## [0.4.0] - 2026-10-22

### Added

- `linuxpkg init --moon [DIR]` writes a `linuxpkg.json` for the native executable of a MoonBit project (reads `moon.mod` or
  `moon.mod.json`, finds the `pkgtype(kind: "executable")` packages, `--bin` picks one).
- Browser build: the `web` package compiles to JavaScript (`lp_inspect`, `lp_verify`, `lp_build`) and `site/` is a static
  bilingual page on GitHub Pages that inspects, verifies and builds packages locally; CI compares its output with the
  command line under Node.
- `sign` package: OpenPGP signing and verification without gpg. `SigningKey` reads an unprotected version 4 RSA or
  Ed25519 private key (armored or binary) and writes binary or armored detached signatures and cleartext-signed
  messages; `PublicKeyring` checks them. The signature time is a parameter, so RSA and Ed25519 signatures are
  reproducible: the same input gives the same bytes on every backend. Built on the low-level packages of
  `justinwongcn/moonpgp`.
- `linuxpkg repo <dir> --sign-key KEY` writes `InRelease` and `Release.gpg` (apt) and `repodata/repomd.xml.asc`
  (dnf); library: `repo.sign_apt`, `repo.sign_yum`, `repo.check_apt_signature`, `repo.check_yum_signature`.
- `linuxpkg build --sign-key KEY` (or `"sign_key"` in the configuration): rpm packages get an OpenPGP signature over
  the main header in the signature header (tag 268 for RSA, 267 for Ed25519, as `rpmsign` writes it; `rpm -K` shows
  `Header V4 RSA/SHA256 Signature ... OK`), Arch packages a detached `<package>.sig` next to them. Library:
  `rpm.sign`, `RpmPackage::signature_status`. Debian packages are not signed one by one: sign the repository.
- `linuxpkg verify <package> [--keyring KEY]` reports the signature of rpm and Arch packages and checks it against
  the keys given; `verify <directory> --keyring KEY` checks `InRelease`, `Release.gpg` and `repomd.xml.asc`.
  A package without a valid signature fails with exit status 2 when a keyring is given.
- Alpine packages are signed too (RSA keys): `build --sign-key KEY [--apk-key-name NAME]` puts a `.SIGN.RSA256.<name>`
  signature stream in front of the package, `linuxpkg key apk-pub KEY` exports the `.rsa.pub` file for
  `/etc/apk/keys/` (and `key info` shows a key), `verify --keyring` accepts that file; `apk add` installs without
  `--allow-untrusted`. Library: `apk.sign`, `apk.sign_index`, `SigningKey::rsa_sign`, `rsa_public_pem`,
  `PublicKeyring::from_pem`, `verify_rsa`.
- `linuxpkg repo <dir>` also writes pacman databases (`--format arch --name NAME`: `NAME.db`, `NAME.files`, as `repo-add`)
  and Alpine repositories (`--format apk`: `<arch>/APKINDEX.tar.gz` equal to `apk index`'s output, packages beside it),
  signed with `--sign-key`; `verify <dir> --keyring KEY` checks them. `--format all` now includes both. Library:
  `repo.arch_index`, `apk_index`, `sign_arch`, `sign_apk`, `check_arch*`, `check_apk*`.
- Checked with `rpm -K`, `gpgv`, `rpmsign` (its signatures verify with `verify --keyring`), apt, dnf and pacman
  (`LocalFileSigLevel = Required`) in the Debian, Ubuntu, Fedora, openEuler and Arch containers, including changed
  and unsigned packages being refused.

### Changed

- `repo` writes the files of an index sorted byte by byte (the standard string comparison looks at the length first);
  `--format all` of `repo` and `verify` now cover Arch and Alpine as well.
- The CI coverage floor is 90% (measured 92.8%); 453 tests.

### Known limits

- Encrypted private keys are refused; Alpine signatures are RSA only; no bzip2; the pure-MoonBit zstd and xz encoders are
  slow (about 0.3 and 0.5 MB/s) and weaker than the official ones, so gzip stays the default.

## [0.3.1] - 2026-10-20

### Changed

- xz packages are now written with `lin2077-zeming/moonxz` (level 9) instead of `lzma-mbt`: the output is smaller than
  gzip (594 KB against 637 KB on 2.4 MB of source text; lzma-mbt gave 690 KB), passes `xz -t`, and a 6 MB tree builds in
  1.7 s instead of 7.6 s. Reading xz and `.lzma` still uses lzma-mbt.
- The CI job that installs packages in containers is named after all six distributions it covers.

## [0.3.0] - 2026-10-20

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

- `arch` package, `build --format arch` and `inspect` / `verify` for Arch Linux packages (`.pkg.tar.zst`, also xz, gzip
  or plain): `.PKGINFO`, a gzip-compressed `.MTREE` with SHA-256 of every file, `.INSTALL` from the maintainer scripts.
  `Arch::pacman_name`, a `pacman` configuration object (default compression zstd); `--format all` now includes it.
  Checked with bsdtar, `pacman -U` / `-Qkk` / `-R` in an archlinux container, and the real `makepkg`.

- `apk` package and `build --format apk` (`inspect` / `verify` recognise `.apk` too): Alpine Linux packages, format 2 — a
  control stream with `.PKGINFO` and scripts, a data stream with `APK-TOOLS.checksum.SHA1` PAX records, `datahash`.
  `tar.build_with_records` / `parse_with_records` carry extra PAX records and allow an archive without end marker;
  `compress.gzip_members` splits files made of several gzip streams. `--format all` now includes apk too.
  Checked with Python's tarfile, the real apk-tools (`apk add`, `apk audit`) and an alpine container.

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
