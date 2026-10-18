# Third-party software and references

linuxpkg is licensed under the Apache License 2.0 (see `LICENSE`).

## Libraries linked into linuxpkg

| Module | License | Used for |
|---|---|---|
| [`moonbit-community/flate`](https://mooncakes.io/docs/moonbit-community/flate) | Apache-2.0 | gzip compression and decompression (`@gzip`) |
| [`moonbitlang/x`](https://mooncakes.io/docs/moonbitlang/x) (`crypto`, `fs`, `sys`) | Apache-2.0 | MD5 / SHA digests, file access and exit codes in the command line |
| [`moonbitlang/core`](https://github.com/moonbitlang/core) | Apache-2.0 | standard library |

## Specifications and projects consulted

No source code of the projects below is copied into linuxpkg. They were read for format knowledge or
naming, and everything was re-implemented in MoonBit.

| Project | License | How it was used |
|---|---|---|
| [google/rpmpack](https://github.com/google/rpmpack) | Apache-2.0 | Reference for the RPM header layout, tags and immutable regions that the `rpm` package will implement (planned; not yet used by any released code). Re-designed in MoonBit, not translated line by line. |
| [goreleaser/nfpm](https://github.com/goreleaser/nfpm) | MIT | Naming of the `linuxpkg.json` fields (`contents`, `src`, `dst`, `type`, `file_info`, ...). No code copied. |
| [Debian Policy Manual](https://www.debian.org/doc/debian-policy/) and `deb(5)`, `deb-control(5)` | documentation | Layout of the deb container, the control file and maintainer scripts. |
| [rpm.org file format documentation](https://rpm-software-management.github.io/rpm/manual/format.html) | documentation | RPM lead, signature header and payload layout (planned). |
| POSIX `pax` / ustar, GNU tar manual | documentation | tar header layout, prefix splitting, PAX records and GNU long names. |

Compatible MoonBit packages we know of and deliberately did not depend on:
[`xmyd0915/moonar`](https://mooncakes.io/docs/xmyd0915/moonar) (ar archives) and
[`oilleelssq-wq/moon-cpio`](https://mooncakes.io/docs/oilleelssq-wq/moon-cpio) (cpio archives).

## Tools used only for verification

`dpkg-deb`, `dpkg`, `lintian`, GNU `tar` and GNU `ar` are run by `tools/oracle/` and by the CI to
check linuxpkg's output. They are not distributed with, or linked into, linuxpkg. Byte sequences
produced by GNU tar 1.34 and dpkg-deb 1.21 are stored as test fixtures
(`archive/tar/fixtures_test.mbt`, `deb/fixtures_test.mbt`); the scripts that regenerate them are in
`tools/oracle/`.
