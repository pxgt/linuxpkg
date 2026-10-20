# File formats and where reality differs from the specification

This page describes what linuxpkg writes and reads. Whenever a specification and the official tools
disagreed, the tools won, and the difference is listed here.

## Compression (deb members and rpm payloads)

The `compress` package is the single place where bytes are compressed or unpacked.

| Format | Written with | Read with | Notes |
|---|---|---|---|
| none | — | — | `data.tar`, rpm `PAYLOADCOMPRESSOR identity` |
| gzip | [moonbit-community/flate](https://mooncakes.io/docs/moonbit-community/flate) | same | default |
| xz | [aurora0x27/lzma-mbt](https://mooncakes.io/docs/aurora0x27/lzma-mbt) | same | CRC32/CRC64/SHA-256 checks, several blocks and streams |
| zstd | [Milky2018/zstd](https://mooncakes.io/docs/Milky2018/zstd) level 9 | same | frame checksum written; skippable and concatenated frames read |
| lzma (`.lzma`) | not written | lzma-mbt | old `lzma_alone` files, e.g. `data.tar.lzma` |
| bzip2 | not supported | not supported | no pure-MoonBit implementation exists; reported as `Unsupported` |

The format of a stream is chosen by the member suffix (deb: `.gz`, `.xz`, `.zst`, `.lzma`) or by the
`PAYLOADCOMPRESSOR` tag (rpm: `gzip`, `xz`, `zstd`, `lzma`, `identity`). `compress.detect` recognises streams by their
signature (`1f 8b`, `fd 37 7a 58 5a 00`, `28 b5 2f fd`, plausible `.lzma` header).

**Bounded unpacking.** Every reader takes a limit (default 1 GiB) on the unpacked size.
- gzip is unpacked in 64 KiB steps and stops at the limit.
- zstd: the unpacked size is bounded from the frame headers (`decompress_bound`: declared content size, or
  the block count × 128 KiB) before anything is decoded.
- xz: the library decodes a whole block at once, so the size is measured first by walking the block headers and the
  LZMA2 chunk headers (a few bytes per 2 MiB chunk) without decoding; the dictionary is limited to 256 MiB.
- `.lzma` files that store their size are checked against the limit; files without a stored size are only
  unpacked when the input is small enough (`input × 4096 ≤ limit`).

**What the compressors achieve** (measured with the release build on wasm-gc; the real tools for comparison):

| Input | gzip -9 | xz -6 | zstd -9 | linuxpkg gzip | linuxpkg xz | linuxpkg zstd (level 9) |
|---|---|---|---|---|---|---|
| 2.4 MB of source text | 624 KB | 505 KB | 590 KB | 637 KB | 690 KB | 1 484 KB |
| 6 MB of executables and docs | 2 261 KB | 1 766 KB | 2 098 KB | 2 275 KB | 2 253 KB | 5 982 KB |

- The xz encoder in lzma-mbt always writes one block with a fixed strategy (the preset has no effect on the output)
  and is slow: a 6 MB tree takes 7.6 s on the native backend (about 0.8 MB/s; the wasm backends are several times
  slower). Its output is valid (`xz -t`, `dpkg`, `rpm` accept it) but 10–40 % larger than `xz -6`.
- The zstd encoder only compresses from level 9 up. At levels 1–7 it stores blocks uncompressed, and no
  level reaches the ratio of the reference `zstd` (levels above 9 gain under 1 %), so linuxpkg uses level 9.
  Packages with a zstd payload are therefore **valid but larger than gzip ones**; choose zstd when the target
  requires it (for example repositories that only accept `.zst` debs), gzip otherwise.
- Unpacking is fast enough for real packages: `verify` of a 6 MB deb takes 0.03 s (gzip), 0.10 s (zstd) and 0.28 s (xz)
  with the native release build, using under 80 MB of memory. Debug builds (what `moon test` uses) are orders of
  magnitude slower for xz, so the tests keep their xz inputs small.

## ar (outer container of a deb)

- Global header `!<arch>\n`, then members with a 60-byte header: name (16, space padded, **no** trailing
  `/`), mtime (12, decimal), uid (6), gid (6), mode (8, octal, `100644`), size (10, decimal), `` `\n ``.
- Data is padded with `\n` to an even length. A missing final padding byte is tolerated when reading.
- Writer: names of 1–16 bytes without `/`, control characters or a trailing space.
- Reader: also understands GNU names (`name/`, long names through the `//` table, symbol tables `/`
  and `/SYM64/`) and BSD long names (`#1/<length>`).

## tar (data and control archive of a deb)

- ustar headers (`ustar\0` + `00`), checksum with the field read as spaces, `devmajor`/`devminor` written as
  `0000000\0` like GNU tar. Output is byte-identical to GNU tar 1.34 for ordinary trees and for names that
  use the ustar `prefix` field (the split is the longest possible prefix, as GNU tar does).
- Names that do not fit even with a prefix, and link targets over 100 bytes, use one of two encodings
  (`long_names`):
  - `Pax` (default): an `x` entry named `PaxHeaders/<basename>` with `path=` / `linkpath=` records.
  - `Gnu`: `L` / `K` pseudo entries named `././@LongLink`.
- **Difference found by testing:** `dpkg -i` of Ubuntu 22.04 (dpkg 1.21) fails on PAX headers with
  `unsupported PAX tar header type 'x'`, while `dpkg-deb --contents` and `-x` accept them. Debs therefore
  always use the `Gnu` encoding, which is what `dpkg-deb` writes itself.
- Reader: ustar, GNU (`L`, `K`, base-256 numbers) and PAX (`path`, `linkpath`, `size`, `uid`, `gid`, `mtime`,
  `uname`, `gname`; global `g` headers are skipped). Hard links and special files are reported (`Hardlink`,
  `Special`), never created. Every header checksum is verified.

## deb

- Members in this order: `debian-binary` (`2.0\n`), `control.tar<ext>`, `data.tar<ext>`, where `<ext>` is `.gz`
  (default), `.xz`, `.zst` or empty (uncompressed). Both archives always use the same compression.
- `control`: Debian field order (`Package`, `Version`, `Architecture`, `Maintainer`, `Installed-Size`,
  relations, `Section`, `Priority`, `Homepage`, `Description`). Continuation lines start with one space, empty
  lines are written as ` .`. Version is `[epoch:]version-release`.
- `md5sums` lists every regular file (conffiles included); `conffiles` lists configuration files;
  `preinst`/`postinst`/`prerm`/`postrm` have mode 0755 and must start with `#!`.
- The data archive starts with `./`, contains every parent directory and is sorted by the byte order of the
  path (so `./usr/bin-extra` sorts before `./usr/bin/x`). Owners are written as names, numeric ids are 0.
- Reading: gzip, xz, zstd, lzma and uncompressed members, in any combination (the control and data archive may
  differ). bzip2 members and unknown suffixes are reported as `Unsupported`, never as corruption.

## Arch Linux package (`.pkg.tar.zst`)

- A tar archive (compressed with zstd like makepkg, or xz, gzip or not at all; file name
  `name-[epoch:]version-release-arch.pkg.tar[.zst|.xz|.gz]`). pacman and libarchive detect the compression from the data.
- Entries in this order: `.INSTALL` (only with maintainer scripts), `.MTREE`, `.PKGINFO`, then the files with paths
  relative to `/` (`usr/bin/hello`), sorted by path, every parent directory present with a trailing slash. Hard links
  and special files are not written.
- `.PKGINFO`, key order as in makepkg: `pkgname`, `pkgbase`, `xdata = pkgtype=pkg`, `pkgver` (`[epoch:]version-release`),
  `pkgdesc` (first line of the description), `url`, `builddate`, `packager`, `size` (bytes of regular files), `arch`,
  `license`, `replaces`, `conflict`, `provides`, `backup` (configuration files without the leading `/`), `depend`, `optdepend`.
- `.MTREE`: gzip-compressed mtree v2 text, `/set type=file uid=0 gid=0 mode=644`, then one line per entry with `time`,
  `mode` (when it is not 644), `size` and `sha256digest` for files, `type=dir`, or `type=link link=...`; bytes that mtree
  cannot carry in a path are written as `\ooo`. It covers `.PKGINFO` and `.INSTALL` but not itself. `pacman -Qkk` and
  `linuxpkg verify` compare the installed or unpacked files with it.
- `.INSTALL`: bash functions `pre_install`, `post_install`, `pre_remove`, `post_remove` holding the scripts without their
  `#!` line, plus `pre_upgrade` / `post_upgrade` that call the install ones (a deb or an rpm runs its install scripts on
  upgrades too).
- Mapping: `depends` → `depend`; `recommends` and `suggests` → `optdepend` (pacman has one kind of weak dependency);
  `conflicts` → `conflict`; `replaces` → `replaces`; `provides` → `provides` (only `=` is allowed there); relations are
  written without spaces (`glibc>=2.31`). `config` files → `backup`.
- Architectures: `amd64` → `x86_64`, `arm64` → `aarch64`, `i386` → `i686`, `armhf` → `armv7h`, `ppc64le` →
  `powerpc64le`, `riscv64`, `loong64`, `all` → `any`. `armel`, `s390x` and `mips64le` have no Arch Linux port and are
  rejected. The release must be a number such as `1` or `1.1` (pkgrel), the version must not contain a hyphen.
- Not written: `.BUILDINFO` (makepkg's record of the build environment; pacman does not need it), `.CHANGELOG`, signatures.
  Reading accepts all of them. Owners other than root are written as names in the tar, while `.MTREE` records numeric
  ids 0, so `pacman -Qkk` may report a uid/gid difference for such files.
- Reading: the package is unpacked with a size limit like the others; `verify` checks every `.MTREE` line (type, mode,
  size, SHA-256, link target), that no file is missing from or extra to the list, and the safety of the paths.

## cpio (payload of an rpm)

- `newc` (`070701`): 110-byte header of 13 eight-digit hex fields, NUL terminated name, header and data padded to
  4 bytes, final record `TRAILER!!!`.
- **Difference:** GNU cpio writes the hex digits in upper case and pads the archive to 512 bytes; librpm and
  linuxpkg write lower case and stop after the trailer. Readers accept both, and `070702` (crc) archives.

## rpm

- Lead: 96 bytes — magic `ed ab ee db`, version 3.0, type 0, arch 1, 66-byte label `name-version-release`,
  OS 1, signature type 5, 16 reserved bytes.
- Signature header, padded to an 8-byte boundary, then the main header, then the payload.
- Header: magic `8e ad e8 01 00 00 00 00`, entry count, data size, 16-byte index entries sorted by tag, data section
  with INT16/INT32/INT64 aligned to their size. The **immutable region** (tag 62 for the signature header, 63 for
  the main header) is the first index entry, a BIN of 16 bytes whose offset points at the trailer, the last 16
  bytes of the data section: `(tag, 7, -(16 × entries), 16)`.
- Signature header: `SIZE` (1000: main header + compressed payload), `SHA256` (273: hex of the main header
  bytes), `PAYLOADSIZE` (1007: uncompressed cpio size). No GPG signature is written.
- Main header: identity and description tags (summary and description as I18N strings), file list as parallel
  arrays (`BASENAMES`, `DIRNAMES`, `DIRINDEXES`, sizes, modes, mtimes, SHA-256 `FILEDIGESTS` with
  `FILEDIGESTALGO` 8, link targets, flags, owners, inodes), scriptlets with interpreter `/bin/sh`,
  `PAYLOADFORMAT cpio`, `PAYLOADCOMPRESSOR` (`gzip` by default, `xz`, `zstd`; left out for an uncompressed
  payload, as rpmbuild does) with `PAYLOADFLAGS` (the level), `PAYLOADDIGEST` (SHA-256 of the *compressed* payload).
- Dependencies: names, `RPMSENSE` flags (`<` 2, `>` 4, `=` 8, combinations for `<=` and `>=`) and versions for
  `Requires`, `Provides`, `Conflicts`, `Obsoletes` (`replaces`), `Recommends` and `Suggests`. The package always
  provides itself (`name = [epoch:]version-release`) and requires the `rpmlib()` features it uses
  (`CompressedFileNames`, `FileDigests`, `PayloadFilesHavePrefix`), plus `rpmlib(PayloadIsXz) <= 5.2-1` for xz or
  `rpmlib(PayloadIsZstd) <= 5.4.18-1` for zstd payloads (flags `RPMSENSE_LESS | RPMSENSE_EQUAL | RPMSENSE_RPMLIB`,
  the last being `1 << 24`), so an rpm that cannot unpack the payload refuses the package. All sets are sorted by name.
- Only files explicitly listed (including directories) are owned by the package; parents are created by rpm.
- Configuration files carry `RPMFILE_CONFIG` (1). rpmbuild's `%config(noreplace)` is 17; linuxpkg does not
  write the `noreplace` bit.
- Files are ordered by the byte order of their absolute path; header arrays and cpio payload use the same order.
- Reading: the payload is kept compressed until it is needed, then unpacked with the compressor named in the
  header (gzip, xz, zstd, lzma or none; when the tag is absent the payload's signature decides). `verify` checks the
  digests of the signature header (SHA-256, SHA-1, MD5), the payload digest and every file. Other compressors
  (bzip2) are `Unsupported`: `inspect` still works, `verify` says that the contents were not checked.
- File sizes above 2 GiB and modification times after January 2038 are rejected when building (32-bit tags).
