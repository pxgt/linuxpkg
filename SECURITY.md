# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on
https://github.com/pxgt/linuxpkg, or open a minimal public issue asking for a private channel if that is
unavailable. Do not post exploit details in public issues. Expect an answer within a few days.

## What counts

linuxpkg parses untrusted files (`.deb`, `.rpm`, tar, ar, cpio, gzip, xz, zstd, lzma) and untrusted configuration. Reports are
welcome for:

- a crash, hang or out-of-memory caused by a crafted input (all readers are expected to return a typed error);
- a package that `verify` accepts although its content differs from its checksums;
- a path in a built package that escapes the installation root;
- an input that makes the command line write outside the requested output directory.

## Design notes

- Readers check every length against the real input size, cap entry counts, and cap the unpacked size of every
  compressed stream (default 1 GiB): gzip stops at the limit while decoding, xz and zstd measure the unpacked
  size from the block and frame headers before decoding anything, so a small compressed input cannot allocate
  unbounded memory. The xz dictionary is limited to 256 MiB. See `docs/formats.md`.
- Install paths in built packages must be absolute and free of `..`, `.` and `//`; nothing can be placed below a
  symlink or file of the same package.
- linuxpkg never extracts packages and never runs maintainer scripts; it only reads and writes archives.
- Packages are not signed. Do not treat a successful `verify` as proof of origin: it only checks that the content
  matches the digests stored inside the same file.
