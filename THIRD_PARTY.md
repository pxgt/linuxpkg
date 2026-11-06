# Third-party software and references

linuxpkg is licensed under the Apache License 2.0 (see `LICENSE`). The copyright and license of every file
in the repository is recorded in `REUSE.toml` and checked with `reuse lint` in the CI
([REUSE](https://reuse.software)); where every piece of test data comes from is listed in
[testdata/PROVENANCE.md](testdata/PROVENANCE.md), which `tools/check_provenance.py` keeps complete.

## Code compiled or linked into linuxpkg

| Component | License | Used for |
|---|---|---|
| [`moonbit-community/flate`](https://mooncakes.io/docs/moonbit-community/flate) | Apache-2.0 | gzip compression and decompression (`@gzip`) |
| [`Milky2018/zstd`](https://mooncakes.io/docs/Milky2018/zstd) (repository `moonbit-community/zstd`) | Apache-2.0 | zstd compression and decompression (`@zstd`) for deb members and rpm payloads |
| [`lin2077-zeming/moonxz`](https://mooncakes.io/docs/lin2077-zeming/moonxz) | Apache-2.0; contains code ported from [ulikunitz/xz](https://github.com/ulikunitz/xz) under BSD-3-Clause (Copyright (c) 2014-2022 Ulrich Kunitz), whose notice is in the module's `LICENSES/` and is reproduced in THIRD_PARTY_NOTICES | xz compression (`@moonxz`), because its encoder compresses better and faster than lzma-mbt's |
| [`justinwongcn/moonpgp`](https://mooncakes.io/docs/justinwongcn/moonpgp) | Apache-2.0 | OpenPGP building blocks for signing (`sign` package): packet parsing and serialising (`packet`), RSA PKCS#1 v1.5 and Ed25519 (`pki`), ASCII armor decoding (`armor`) and hashes (`primitives`). Only these four low-level packages are imported. |
| [`aurora0x27/lzma-mbt`](https://mooncakes.io/docs/aurora0x27/lzma-mbt) | Apache-2.0 | xz decompression and reading of `.lzma` files (`@lzma`) |
| [`moonbitstack/moonyaml`](https://mooncakes.io/docs/moonbitstack/moonyaml) | Apache-2.0 | YAML 1.2 reader for `nfpm.yaml` (`nfpm` package) |
| [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) (`crypto`, `fs`, `sys`) | Apache-2.0 | MD5 / SHA digests, file access and exit codes in the command line |
| [`moonbitlang/core`](https://github.com/moonbitlang/core) | Apache-2.0, with a NOTICE (code adapted from fdlibm, V8, Go, musl, Arm and FreeBSD) that is reproduced in THIRD_PARTY_NOTICES | standard library |
| MoonBit C runtime (from the toolchain) | Apache-2.0 | native programs only |
| [simdutf](https://github.com/simdutf/simdutf) (from the toolchain) | Apache-2.0 OR MIT | UTF-8 / UTF-16 routines of native programs |
| [GNU C Library](https://www.gnu.org/software/libc/) | LGPL-2.1-or-later | statically linked into the Linux programs we publish (not into the library, the JavaScript build or programs you build yourself) |
| libgcc, the GCC runtime library | GPL-3.0-or-later WITH GCC-exception-3.1 | statically linked into the Linux programs we publish |

## What goes with the files we distribute

From version 0.5.1 on:

* **THIRD_PARTY_NOTICES** lists the components above with their copyright notices, the NOTICE files and the
  full license texts. `tools/notices/make_notices.py` writes it from the files of the modules and the
  toolchain, and fails rather than write an incomplete file. It is in every release tarball next to
  `LICENSE`, every package installs it as `/usr/share/doc/<name>/THIRD_PARTY_NOTICES`, and the web page links
  its own version, for the JavaScript build, as `THIRD_PARTY_NOTICES.txt`.
* **The source of the linked glibc.** The Linux programs are statically linked with the glibc of Ubuntu
  22.04. `tools/notices/prepare_dist.sh` downloads the Ubuntu source package of that exact version (its
  `.dsc` and every file it lists, checked against the `.dsc`) and it is published at the same place as the
  programs: as assets of the GitHub release, and under https://pxgt.github.io/linuxpkg/sources/ for the
  package repositories. THIRD_PARTY_NOTICES says how to relink linuxpkg against a modified glibc; the
  complete source of linuxpkg is at the tag of the release.
* `tools/notices/check_dist.py` checks in the release and Pages workflows that every tarball and package
  carries the notices and that the glibc source named in them is there.

The release assets of 0.4.0 and 0.5.0 were statically linked programs without these materials; their
binary assets were removed and 0.5.1 replaces them.

## Third-party programs in the test data of versions 0.3.0 to 0.5.0

Versions **0.3.0, 0.3.1, 0.4.0 and 0.5.0** (the git tags, the GitHub releases and the packages on
mooncakes.io, which contain the test files) store two binary packages of Linux distributions as test
fixtures. They were removed from the repository in 0.5.1 and replaced by packages that the official
abuild and makepkg write from our own files (see [testdata/PROVENANCE.md](testdata/PROVENANCE.md)).

| | tree | which |
|---|---|---|
| Stored in | `apk/fixtures_test.mbt`, constant `real_tree_package` | `arch/fixtures_test.mbt`, constant `real_which_package` |
| Package | `tree-2.1.1-r0.apk`, Alpine Linux v3.20 main, x86_64, aports commit `91eab88679a105ec6f6f0c5f52698438bc01c50f` | `which-2.25-1-x86_64.pkg.tar.zst`, Arch Linux core |
| Contains | `/usr/bin/tree` | `/usr/bin/which`, `which.info.gz`, `which.1.gz` |
| License | GPL-2.0-or-later | the program GPL-3.0-or-later; the manual may be copied verbatim provided its copyright notice and permission notice are preserved |
| Copyright | Copyright (c) 1996 - 2023 by Steve Baker; `strverscmp.c`: Copyright (C) 1997, 2002, 2005 Free Software Foundation, Inc. | Copyright (C) 1999, 2003, 2007, 2008, 2024, 2026 Carlo Wood; parts (`getopt`, `tilde`, `bash.c`): Copyright Free Software Foundation, Inc.; manual: Copyright 2000 - 2025 by Carlo Wood |
| Upstream | https://oldmanprogrammer.net/source.php?dir=projects/tree | https://savannah.gnu.org/projects/which/ |
| Corresponding source | `unix-tree-2.1.1.tar.gz` (the SHA-512 in the APKBUILD matches) and the `APKBUILD` of aports at that commit | `which-2.25.tar.gz` (the BLAKE2 sum in the PKGBUILD matches) and the `PKGBUILD` of `archlinux/packaging/packages/which` at tag `2.25-1` |

**Where to get the source.** All of it, unchanged, with the full GPL-2.0 and GPL-3.0 texts and a README
with the checksums, is the asset `third-party-sources-tree-2.1.1-which-2.25.tar.gz` of each of the four
releases:
[v0.3.0](https://github.com/pxgt/linuxpkg/releases/tag/v0.3.0),
[v0.3.1](https://github.com/pxgt/linuxpkg/releases/tag/v0.3.1),
[v0.4.0](https://github.com/pxgt/linuxpkg/releases/tag/v0.4.0),
[v0.5.0](https://github.com/pxgt/linuxpkg/releases/tag/v0.5.0).
The same files are also available from their upstreams and from the Alpine and Arch Linux source
repositories named above.

## Specifications and projects consulted

No source code of the projects below is copied into linuxpkg. They were read for format knowledge or
naming, and everything was re-implemented in MoonBit.

| Project | License | How it was used |
|---|---|---|
| [google/rpmpack](https://github.com/google/rpmpack) | Apache-2.0 | Reference for the RPM header layout, tags and immutable regions implemented in the `rpm` package. The layout is checked against rpm 4.17 itself (`rpm -K`, `rpm -V`, installs in Fedora and openEuler). Re-designed in MoonBit, not translated line by line; no code copied. |
| [goreleaser/nfpm](https://github.com/goreleaser/nfpm) | MIT | Naming of the `linuxpkg.json` fields (`contents`, `src`, `dst`, `type`, `file_info`, ...), which `.PKGINFO` fields its archlinux packager writes, and the configuration format that the `nfpm` package reads (field names, overrides, environment variables, version splitting, the destination rules of globs: the rules were read in `nfpm.go`, `files/files.go` and `internal/glob` and re-implemented in MoonBit, no code copied). Its acceptance configurations and the files they use are stored unchanged in `testdata/nfpm/` (MIT, see `testdata/nfpm/README.md` and `testdata/nfpm/LICENSE`) and the released binary is downloaded, with its checksum checked, by the CI to compare packages. |
| [Alpine apk-tools](https://gitlab.alpinelinux.org/alpine/apk-tools) and the [abuild](https://gitlab.alpinelinux.org/alpine/abuild) / [package format](https://wiki.alpinelinux.org/wiki/Apk_spec) documentation | GPL-2.0-only (code, not used) / documentation | Layout of `.PKGINFO`, the control and data streams, `datahash` and the `APK-TOOLS.checksum.SHA1` records. No apk-tools code is used or copied. The test fixture is a package that the real abuild writes from our own files. |
| [Arch Linux pacman / makepkg](https://gitlab.archlinux.org/pacman/pacman) and the [PKGBUILD](https://wiki.archlinux.org/title/PKGBUILD) / [Creating packages](https://wiki.archlinux.org/title/Creating_packages) documentation | GPL-2.0-or-later (code, not used) / documentation | Layout of `.PKGINFO`, `.MTREE` and `.INSTALL`. No pacman code is used or copied. The test fixture is a package that the real makepkg writes from our own files. |
| Go standard library `os.Expand` | BSD-3-Clause | The rules of `$VAR` / `${VAR}` expansion in nFPM files (`nfpm/env.mbt`) follow it, including its corner cases; written again in MoonBit. |
| [Masterminds/semver](https://github.com/Masterminds/semver) `NewVersion` | MIT | How nFPM splits `v1.2.3-rc.1+git` (`nfpm/version.mbt`); behaviour re-implemented, no code copied. |
| [justinwongcn/moonpgp](https://github.com/justinwongcn/moonpgp) `api/sign.mbt`, `api/key.mbt` | Apache-2.0 | Read for the order of steps of an OpenPGP v4 signature (hashed subpackets, trailer, hash prefix check). The `sign` package assembles its own signatures from moonpgp's public low-level packages, so that the signature time is a parameter and the same input gives the same bytes. No code copied. |
| [RFC 4880](https://www.rfc-editor.org/rfc/rfc4880) / [RFC 9580](https://www.rfc-editor.org/rfc/rfc9580) (OpenPGP) | specification | Signature packets, subpackets, ASCII armor and cleartext signatures (section 7). |
| [Debian Policy Manual](https://www.debian.org/doc/debian-policy/) and `deb(5)`, `deb-control(5)` | documentation | Layout of the deb container, the control file and maintainer scripts. |
| [rpm.org file format documentation](https://rpm-software-management.github.io/rpm/manual/format.html) | documentation | RPM lead, signature header, tag numbers and payload layout. |
| POSIX `pax` / ustar, GNU tar manual | documentation | tar header layout, prefix splitting, PAX records and GNU long names. |

Compatible MoonBit packages we know of and deliberately did not depend on:
[`xmyd0915/moonar`](https://mooncakes.io/docs/xmyd0915/moonar) (ar archives) and
[`oilleelssq-wq/moon-cpio`](https://mooncakes.io/docs/oilleelssq-wq/moon-cpio) (cpio archives).

## Tools used only for verification

`dpkg-deb`, `dpkg`, `lintian`, `pacman`, `makepkg`, `abuild`, `bsdtar`, `apk`, `apt`, `apt-ftparchive`, `dnf`,
`createrepo_c`, `rpm`, `rpmbuild`, `rpm2cpio`, `gpg`, `readelf`, nFPM, GNU `cpio`, GNU `tar` and GNU `ar` are run
by `tools/oracle/`, `tools/elf/`, `tools/nfpm/` and by the CI to check linuxpkg's output. They are not
distributed with, or linked into, linuxpkg. The packages and archives some of them write from our own files
are stored as test fixtures; [testdata/PROVENANCE.md](testdata/PROVENANCE.md) lists each one.
