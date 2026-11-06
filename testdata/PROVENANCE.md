# Provenance of the test data

Every piece of binary data in this repository is listed here: where it is, what made it, whose content it
holds and under which license. `tools/check_provenance.py` runs in the CI and fails when a binary file, a
large hex or base64 constant in a MoonBit file, or a long encoded literal is missing from this list, or
when an entry names a file that no longer exists.

**No third-party program is stored in the repository.** Packages and archives written by the official
tools (dpkg-deb, rpmbuild, abuild, makepkg, GNU tar, GNU cpio, xz, zstd, gzip, gpg) contain only files that
the scripts in `tools/oracle/` write themselves, so they are ours and under the Apache License 2.0 like the
rest of linuxpkg. The one exception is `testdata/nfpm/`, copied unchanged from nFPM (MIT).

## Data in the repository

| File or directory | Constants | Made by | Content | License |
|---|---|---|---|---|
| `apk/fixtures_test.mbt` | `real_abuild_package`, `abuild_test_key` | abuild 3.13.0-r3 of Alpine Linux v3.20, `tools/oracle/make_apk_fixtures.sh` | `tools/oracle/fixture-src/` (a shell script, a configuration file, a README, an install script, written for linuxpkg). Signed with a test-only RSA key made for the occasion: the private half is thrown away, `abuild_test_key` is the public half. | Apache-2.0 |
| `arch/fixtures_test.mbt` | `real_makepkg_package` | makepkg 7.1.0 (pacman) of Arch Linux, `tools/oracle/make_arch_fixtures.sh` | `tools/oracle/fixture-src/` | Apache-2.0 |
| `archive/tar/fixtures_test.mbt` | `ref_tree`, `ref_pax`, `ref_gnu` | GNU tar 1.34, `tools/oracle/make_tar_fixtures.sh` | small files the script writes (`hi`, `#!/bin/sh`, long dummy names) | Apache-2.0 |
| `archive/cpio/fixtures_test.mbt` | `ref_tree` | GNU cpio 2.13, `tools/oracle/make_cpio_fixtures.sh` | small files the script writes | Apache-2.0 |
| `compress/fixtures_test.mbt` | `xz_default`, `xz_crc32`, `xz_sha256`, `xz_nocheck`, `xz_twice`, `xz_blocks`, `lzma_alone`, `zstd_3`, `zstd_19`, `zstd_nocheck`, `zstd_stream`, `gzip_9` | xz 5.2.5, zstd 1.4.8, gzip, `tools/oracle/make_compress_fixtures.sh` | a text the script generates ("line N: the quick brown fox ...") | Apache-2.0 |
| `deb/fixtures_test.mbt` | `real_gzip_deb`, `real_xz_deb`, `real_zstd_deb` | dpkg-deb 1.21.1, `tools/oracle/make_deb_fixtures.sh` | files the script writes (`hello from dpkg-deb`, `setting=1`, a postinst) | Apache-2.0 |
| `rpm/fixtures_test.mbt` | `real_gzip_rpm`, `real_xz_rpm`, `real_zstd_rpm` | rpmbuild 4.17.0, `tools/oracle/make_rpm_fixtures.sh` | files the spec in the script writes | Apache-2.0 |
| `elf/samples_test.mbt` | `samples` | `tools/elf/samples_to_mbt.py` | the files of `testdata/elf/` as base64, with what readelf says about them | Apache-2.0 |
| `spec/elf_check_test.mbt` | | by hand from `testdata/elf/` | `tiny.amd64` and `tiny.arm64` as base64 | Apache-2.0 |
| `testdata/elf/` | | the Ubuntu 22.04 cross compilers (gcc), `tools/elf/make_samples.sh` | `hello.c` and `tiny.c` of this directory, linked with `-nostdlib`: no C library start files and no libgcc are linked in, the script checks the symbols; `hello` only records `NEEDED libc.so.6` and calls `write` and `_exit` in it at run time | Apache-2.0 |
| `testdata/sign/` | | gpg 2.2.27, `tools/oracle/make_sign_fixtures.sh` | throw-away OpenPGP keys made for the tests (public on purpose, worthless) and signatures gpg made over a fixed text | Apache-2.0 |
| `sign/fixtures_test.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the keys and signatures of `testdata/sign/` | Apache-2.0 |
| `apk/sign_fixtures_test.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the test-only keys of `testdata/sign/` | Apache-2.0 |
| `rpm/sign_fixtures_test.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the test-only keys of `testdata/sign/` | Apache-2.0 |
| `repo/sign_fixtures_test.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the test-only keys of `testdata/sign/` | Apache-2.0 |
| `web/sign_fixtures_test.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the test-only keys of `testdata/sign/` | Apache-2.0 |
| `cmd/main/sign_fixtures_wbtest.mbt` | | `tools/oracle/sign_fixtures_to_mbt.py` | the test-only keys of `testdata/sign/` | Apache-2.0 |
| `site/linuxpkg.asc` | | gpg | the public key that signs the package repositories on GitHub Pages | Apache-2.0 |
| `site/linuxpkg.rsa.pub` | | `linuxpkg key apk-pub` | the same key as a PEM RSA public key, for Alpine | Apache-2.0 |
| `testdata/nfpm/` | | copied unchanged from [goreleaser/nfpm](https://github.com/goreleaser/nfpm) v2.48.0 `testdata/` | nFPM's acceptance configurations and the files they install, among them the 52- and 64-byte ELF headers `elf32` and `elf64` | MIT, Copyright (c) 2018 GoReleaser, see `testdata/nfpm/LICENSE` |

## Data the CI downloads and does not keep

To show that linuxpkg reads real distribution packages, `tools/oracle/containers.sh` downloads some
packages inside the distribution containers at run time (`apt-get download hello` on Debian and Ubuntu,
`dnf download` on Fedora and openEuler, `pacman -Sw which tree` on Arch Linux, `apk fetch tree busybox-binsh`
on Alpine), reads and verifies them, and throws the container away. They are not stored in the
repository, uploaded as CI artifacts or published. `tools/nfpm/check.sh` downloads the released nFPM binary
the same way to compare packages with it.

## Earlier versions

Versions 0.3.0, 0.3.1, 0.4.0 and 0.5.0 stored two real distribution packages as test fixtures:
`tree-2.1.1-r0.apk` from Alpine Linux (GPL-2.0-or-later) in `apk/fixtures_test.mbt` and
`which-2.25-1-x86_64.pkg.tar.zst` from Arch Linux (GPL-3.0-or-later) in `arch/fixtures_test.mbt`. They were
replaced by the packages above. Their licenses, copyright holders and corresponding source are described
in [THIRD_PARTY.md](../THIRD_PARTY.md#third-party-programs-in-the-test-data-of-versions-030-to-050).
