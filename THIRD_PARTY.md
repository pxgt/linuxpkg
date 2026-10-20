# Third-party software and references

linuxpkg is licensed under the Apache License 2.0 (see `LICENSE`).

## Libraries linked into linuxpkg

| Module | License | Used for |
|---|---|---|
| [`moonbit-community/flate`](https://mooncakes.io/docs/moonbit-community/flate) | Apache-2.0 | gzip compression and decompression (`@gzip`) |
| [`Milky2018/zstd`](https://mooncakes.io/docs/Milky2018/zstd) (repository `moonbit-community/zstd`) | Apache-2.0 | zstd compression and decompression (`@zstd`) for deb members and rpm payloads |
| [`aurora0x27/lzma-mbt`](https://mooncakes.io/docs/aurora0x27/lzma-mbt) | Apache-2.0 | xz compression and decompression, and reading of `.lzma` files (`@lzma`) |
| [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) (`crypto`, `fs`, `sys`) | Apache-2.0 | MD5 / SHA digests, file access and exit codes in the command line |
| [`moonbitlang/core`](https://github.com/moonbitlang/core) | Apache-2.0 | standard library |

## Specifications and projects consulted

No source code of the projects below is copied into linuxpkg. They were read for format knowledge or
naming, and everything was re-implemented in MoonBit.

| Project | License | How it was used |
|---|---|---|
| [google/rpmpack](https://github.com/google/rpmpack) | Apache-2.0 | Reference for the RPM header layout, tags and immutable regions implemented in the `rpm` package. The layout is checked against rpm 4.17 itself (`rpm -K`, `rpm -V`, installs in Fedora and openEuler). Re-designed in MoonBit, not translated line by line; no code copied. |
| [goreleaser/nfpm](https://github.com/goreleaser/nfpm) | MIT | Naming of the `linuxpkg.json` fields (`contents`, `src`, `dst`, `type`, `file_info`, ...), and which `.PKGINFO` fields its archlinux packager writes. No code copied. |
| [Arch Linux pacman / makepkg](https://gitlab.archlinux.org/pacman/pacman) and the [PKGBUILD](https://wiki.archlinux.org/title/PKGBUILD) / [Creating packages](https://wiki.archlinux.org/title/Creating_packages) documentation | GPL-2.0-or-later (code, not used) / documentation | Layout of `.PKGINFO`, `.MTREE` and `.INSTALL`; packages written by makepkg 7.1 are stored as a test fixture. No pacman code is used or copied. |
| [Debian Policy Manual](https://www.debian.org/doc/debian-policy/) and `deb(5)`, `deb-control(5)` | documentation | Layout of the deb container, the control file and maintainer scripts. |
| [rpm.org file format documentation](https://rpm-software-management.github.io/rpm/manual/format.html) | documentation | RPM lead, signature header, tag numbers and payload layout. |
| POSIX `pax` / ustar, GNU tar manual | documentation | tar header layout, prefix splitting, PAX records and GNU long names. |

Compatible MoonBit packages we know of and deliberately did not depend on:
[`xmyd0915/moonar`](https://mooncakes.io/docs/xmyd0915/moonar) (ar archives) and
[`oilleelssq-wq/moon-cpio`](https://mooncakes.io/docs/oilleelssq-wq/moon-cpio) (cpio archives).

## Tools used only for verification

`dpkg-deb`, `dpkg`, `lintian`, `pacman`, `makepkg`, `bsdtar`, `apt`, `apt-ftparchive`, `dnf`, `createrepo_c`, `rpm`, `rpmbuild`, `rpm2cpio`, GNU `cpio`, GNU `tar` and GNU `ar` are run by `tools/oracle/` and by the CI to
check linuxpkg's output. They are not distributed with, or linked into, linuxpkg. Byte sequences
produced by GNU tar 1.34, GNU cpio 2.13, dpkg-deb 1.21 and rpmbuild 4.17 are stored as test fixtures
(`archive/tar/fixtures_test.mbt`, `archive/cpio/fixtures_test.mbt`, `deb/fixtures_test.mbt`, `rpm/fixtures_test.mbt`, `arch/fixtures_test.mbt`); the scripts that regenerate them are in
`tools/oracle/`.
