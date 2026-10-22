# Development log

What went wrong and what was learned, in the order it happened. Every item was found by running a real tool, not by reading
a specification; the fix is in the code and the check that would catch it again is in `tools/oracle/`.

## Packages (October 18–20)

* **`dpkg -i` does not read PAX headers.** The tar writer used PAX extended headers for long names, which `dpkg-deb --contents`
  accepts, but `dpkg -i` on Ubuntu 22.04 stops with `unsupported PAX tar header type 'x'`. Debs now use GNU `L`/`K` long-name
  entries (what `dpkg-deb` itself writes); the tar package has an option for each style.
* **rpm headers are sorted, aligned and have a region.** The index must be sorted by tag, 2- and 4-byte values aligned in the
  data area, and the "immutable region" trailer must count the region entry itself. A hand-computed byte-for-byte test of a
  three-tag header (in `rpm/header_test.mbt`) is the guard.
* **`rpmbuild` leaves out `PAYLOADCOMPRESSOR` for an uncompressed payload.** Writing `identity` there is not accepted;
  the reader now recognises the payload from its bytes.
* **xz written by `lzma-mbt` was larger than gzip** (265 KB against 230 KB on 757 KB of source). An independent review
  found `moonxz` compressing to 210 KB; the encoder was switched, the decoder stayed. The README table has real numbers and
  says plainly that the pure-MoonBit zstd encoder is weak (about 2.4 times gzip on text).
* **apk checksums cover symbolic links too.** The first apk had no `APK-TOOLS.checksum.SHA1` on links; `apk add` warned that
  packages without embedded checksums will be dropped, and `apk audit` flagged the link. The checksum of a link is the SHA-1 of
  its target text. Found by comparing with a real busybox package.
* **A gzip bomb must stop while decoding.** Unpacking first and checking afterwards runs out of memory; the limit is applied
  per chunk, and for xz and zstd the unpacked size is read from the block and frame headers before decoding.

## Language and toolchain

* **`String::replace` replaces the first match only**, which silently broke XML unescaping and the apk `~` to `_` version
  mapping; `replace_all` is the one to use.
* **String comparison looks at the length first.** `"alpha-1.0.apk" < "beta.apk"` is false because the first is longer, so
  `sort()` is no alphabetical order. Repositories use their own byte-wise comparison (`text_compare`); the same applies to
  `Bytes`.
* **Reserved words** (`member`, `package`, `override`, `final`) kept turning up as variable names; the warning is an error under
  `--deny-warn`.
* **A newer toolchain prints `Int32` in `.mbti`** where an older one printed `Int`; CI regenerates the interface files and
  fails on any difference, so formatting and `moon info` run with the same `moon` as CI.
* **Shell quoting loses backslashes.** Writing Python or MoonBit with `\x00` or `\n` through a here-document silently turned
  them into real NUL bytes and newlines (once into `tools/oracle/run.sh`, which Git then treated as binary). Files with
  escapes are written with the editor tools, and CI scans for NUL bytes.

## Signing (October 21–22)

* **`moonpgp` and `flate` disagree about a function name.** `moonpgp` 0.1.0 needs `flate` 0.8 (`zlib_compress`), this package
  uses 0.9 (`compress`), so its `api` and `compress` packages do not build here. Its low-level packages (`packet`, `pki`,
  `armor`, `primitives`) do not use `flate`, so the `sign` package imports only those and assembles the version 4 signatures
  itself. That also fixed a second problem: `moonpgp` stamps signatures with the clock, and ours must be reproducible.
* **`gpgv` refuses a signature that is older than its key** ("Time conflict"). With `SOURCE_DATE_EPOCH=0` the package build
  time is 1970, so the signature time is the larger of the build time and the key's creation time.
* **An rpm signature covers the main header only.** Tag 268 (RSA) or 267 (EdDSA) in the signature header, signature type
  `0x00`; `rpm -K` then shows `Header V4 RSA/SHA256 Signature ... OK`. The payload is protected by the digest inside the
  header. Checked against `rpmsign`'s own output.
* **`abuild-sign` signs the whole file it is given.** For a package, abuild calls it on `control.tar.gz` only and
  concatenates; for an index it signs the full `APKINDEX.tar.gz`. A first experiment signing a complete `.apk` verified over
  control plus data, which is not what `apk add` checks.
* **`apk` takes a package from the directory of its own architecture.** A `noarch` package listed in `x86_64/APKINDEX.tar.gz`
  is fetched from `noarch/<file>.apk`; found with `strace`, after `package mentioned in index not found`.
* **`repo-add` writes less than documented.** No `%MD5SUM%` any more, the `files` list ends with a single newline, and
  `apk index` writes empty `T:`, `U:` and `L:` lines. The containers job compares our databases with the real tools' output
  byte for byte.

## Where the time went

Most of the work was the loop "write it, give it to the official tool, read the complaint". That loop is now a script
(`tools/oracle/run.sh`, about 200 checks) and a container job (six distributions), which is why the later parts of the
project went faster than the earlier ones.
