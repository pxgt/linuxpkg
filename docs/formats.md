# File formats and where reality differs from the specification

This page describes what linuxpkg writes and reads. Whenever a specification and the official tools
disagreed, the tools won, and the difference is listed here.

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

- Members in this order: `debian-binary` (`2.0\n`), `control.tar.gz`, `data.tar.gz`; gzip only.
- `control`: Debian field order (`Package`, `Version`, `Architecture`, `Maintainer`, `Installed-Size`,
  relations, `Section`, `Priority`, `Homepage`, `Description`). Continuation lines start with one space, empty
  lines are written as ` .`. Version is `[epoch:]version-release`.
- `md5sums` lists every regular file (conffiles included); `conffiles` lists configuration files;
  `preinst`/`postinst`/`prerm`/`postrm` have mode 0755 and must start with `#!`.
- The data archive starts with `./`, contains every parent directory and is sorted by the byte order of the
  path (so `./usr/bin-extra` sorts before `./usr/bin/x`). Owners are written as names, numeric ids are 0.
- Reading: xz, zstd, bzip2 and lzma members are reported as `Unsupported`, never as corruption.

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
  `PAYLOADFORMAT cpio`, `PAYLOADCOMPRESSOR gzip`, `PAYLOADDIGEST` (SHA-256 of the *compressed* payload).
- Dependencies: names, `RPMSENSE` flags (`<` 2, `>` 4, `=` 8, combinations for `<=` and `>=`) and versions for
  `Requires`, `Provides`, `Conflicts`, `Obsoletes` (`replaces`), `Recommends` and `Suggests`. The package always
  provides itself (`name = [epoch:]version-release`) and requires the `rpmlib()` features it uses
  (`CompressedFileNames`, `FileDigests`, `PayloadFilesHavePrefix`). All sets are sorted by name.
- Only files explicitly listed (including directories) are owned by the package; parents are created by rpm.
- Configuration files carry `RPMFILE_CONFIG` (1). rpmbuild's `%config(noreplace)` is 17; linuxpkg does not
  write the `noreplace` bit.
- Files are ordered by the byte order of their absolute path; header arrays and cpio payload use the same order.
- Reading: the payload is kept compressed, so xz and zstd packages can still be inspected. `verify` reports
  `Unsupported` for them because the file contents cannot be checked. SHA-256, SHA-1 and MD5 header digests
  of the signature header are checked when present.
- File sizes above 2 GiB and modification times after January 2038 are rejected when building (32-bit tags).
