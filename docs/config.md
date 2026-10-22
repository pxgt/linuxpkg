# `linuxpkg.json` reference

Field names follow [nFPM](https://github.com/goreleaser/nfpm) where they overlap. Unknown fields are
rejected, and every error names its field (for example `contents[2].dst`). Relative file paths (`src`,
`scripts.*`) are resolved against the directory of the configuration file.

## Top level

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | Package name: lowercase, at least two characters, `[a-z0-9][a-z0-9+.-]+`. |
| `version` | string | required | Upstream version: starts with a digit, then letters, digits, `.`, `+`, `~`. Use `1.0~rc1` for pre-releases; `-` and `:` are rejected. |
| `release` | string | `"1"` | Packaging revision (rpm *release*, Debian *revision*): letters, digits, `.`, `+`, `~`. |
| `epoch` | integer | `0` | Epoch, 0 to 2147483647; omitted when 0. |
| `arch` | string | required | `amd64`/`x86_64`, `arm64`/`aarch64`, `i386`/`386`/`i686`, `armhf`/`armv7hl`, `armel`/`armv5tel`, `ppc64le`/`ppc64el`, `s390x`, `riscv64`, `loong64`/`loongarch64`, `mips64le`/`mips64el`, `all`/`noarch`. Converted to each format's own name. |
| `maintainer` | string | required | Single line, conventionally `Name <email>`. Stored as `Maintainer` (deb) and `Packager` (rpm). |
| `description` | string | required | First line is the summary; the rest is the long description. |
| `homepage`, `license`, `vendor` | string | none | Homepage URL, license text, vendor. `license` defaults to `Unspecified` in rpm. |
| `section` | string | `"misc"` | Debian section / rpm group. |
| `priority` | string | `"optional"` | `required`, `important`, `standard`, `optional` or `extra` (deb). |
| `depends`, `recommends`, `suggests`, `conflicts`, `replaces`, `provides` | string array | `[]` | Relations, see below. |
| `mtime` | integer | none | Modification time (seconds since the epoch) of the build and of all entries without their own. Falls back to the `SOURCE_DATE_EPOCH` environment variable, then 0. |
| `compression` | string | `"gzip"` | Compression of the deb members and the rpm payload: `none`, `gzip`, `xz` or `zstd` (`gz` and `zst` are accepted too). See *Compression* below. |
| `deb`, `rpm`, `pacman` | object | none | Per-format overrides. Only `compression` is allowed, for example `"deb": {"compression": "zstd"}`. `pacman` is the Arch Linux package (`arch` is already the CPU architecture); its default is `zstd`. |
| `sign_key` | string | none | Path of an OpenPGP private key (relative to the configuration file) that signs rpm, Arch Linux and Alpine packages; `--sign-key` on the command line wins. See [signing.md](signing.md). |
| `apk_key_name` | string | `linuxpkg-<key id>.rsa.pub` | File name of the public key in Alpine signatures, the name users give it in `/etc/apk/keys/`. |
| `allow_arch_mismatch` | boolean | `false` | Build even if an ELF file in `contents` is for another CPU than `arch` (cross toolchains, firmware). `build --allow-arch-mismatch` does the same. See *ELF files* below. |
| `contents` | object array | `[]` | Files, directories and links, see below. |
| `scripts` | object | none | `preinstall`, `postinstall`, `preremove`, `postremove`: paths of script files; each must start with `#!` for deb. |
| `$schema` | string | ignored | For editors. |

### Compression

The format-specific setting wins over the package-wide one, and `--compression` on the command line wins over
both. The default stays `gzip` because it is the best trade-off with the compressors available in MoonBit:

- `gzip`: smallest result and fast. Understood by every dpkg and rpm.
- `xz`: valid, accepted by `xz -t`, `dpkg` and `rpm`; about 5–6 % smaller than gzip (the reference `xz -6` is 20 % smaller still)
  and fast enough (about 3.5 MB/s native, slower on wasm). rpm gets `rpmlib(PayloadIsXz)` in its requirements.
- `zstd`: for targets that require it. The encoder is far weaker than the reference `zstd` (about 2.4× the size of
  gzip on text), but the package is valid; rpm gets `rpmlib(PayloadIsZstd)`.
- `none`: uncompressed, useful for debugging and for repositories that compress themselves.

Measurements are in [formats.md](formats.md#compression-deb-members-and-rpm-payloads). Reading accepts all of them
(and `.lzma`), whatever the setting was.

### Relations

Written the Debian way (`libc6 (>= 2.31)`) or the RPM way (`glibc >= 2.34`) or without a version (`bash`).
Operators: `<<`/`<`, `<=`, `=`/`==`, `>=`, `>>`/`>`; `<` and `>` are strict. One package per entry; alternatives
(`a | b`) and lists are rejected. `replaces` becomes `Replaces` (deb) / `Obsoletes` (rpm); `recommends` and
`suggests` become the weak dependencies of both formats. `depends` becomes `Depends` / `Requires`.

## `contents` items

| Field | Meaning |
|---|---|
| `dst` | Absolute install path (required): no `..`, `.`, `//`, trailing `/` or control characters. Paths must be unique, and nothing may be installed below a file or a symlink. |
| `type` | `file` (default), `config` (also `config\|noreplace`), `dir` or `symlink`. |
| `src` | For `file`/`config`: file to read. For `symlink`: the link **target** (may be relative). Not allowed for `dir`. |
| `mode` | Octal **string** such as `"0755"` (JSON numbers cannot be octal). Defaults: files `0644`, directories `0755`, symlinks `0777` (not settable). |
| `owner`, `group` | User and group names, default `root`. 1–32 characters of letters, digits, `_`, `-`, `.`. Numeric ids are always written as 0; the package manager resolves the names. |
| `mtime` | Per-entry modification time. |
| `file_info` | nFPM style object holding `mode`, `owner`, `group`, `mtime`. Do not combine it with the flat keys. |

Parent directories: debs and Arch Linux packages list every parent directory automatically; rpms own only the directories you list.

### ELF files

`build` reads the header of every regular file in `contents` that starts with the ELF magic number and compares the CPU it is
built for with `arch`. This stops the most common packaging accident: an arm64 program in an amd64 package.

* A specific `arch` and an ELF file for another CPU: the build **stops** before anything is written, with a message such as
  `contents[0]: /usr/bin/hello is an ELF file for arm64, but the package architecture is amd64`.
* `arch` is `all` (or `noarch`) and the package contains an ELF file: a **warning** on standard error, the build goes on.
* `"allow_arch_mismatch": true` or `--allow-arch-mismatch` silences both.
* An ELF file for a machine that has no package architecture (other CPUs, big-endian PowerPC, x32 and n32 ABIs) is not
  compared. 32-bit ARM is `armhf` when the hard-float flag is set in `e_flags` and `armel` otherwise.

`linuxpkg elf <file> [--json]` shows what the headers say (CPU, 32/64 bit, byte order, static or dynamic, interpreter,
`DT_NEEDED`, `DT_SONAME`), and `inspect` shows the same line under every ELF file of a package; with `--json` each file has an `elf`
object (`null` for other files). `init --moon` uses the architecture of the binary when it is already built.

## nFPM files

`build` and `convert` also read an nFPM configuration (`nfpm.yaml`), see [nfpm.md](nfpm.md).

## Command line

```
linuxpkg build <config.json> [--format deb|rpm|arch|apk|all] [--compression none|gzip|xz|zstd] [--sign-key KEY] [--apk-key-name N] [--allow-arch-mismatch] [--out DIR]
linuxpkg inspect <file.deb|file.rpm> [--json]
linuxpkg elf <file> [--json]
linuxpkg convert <nfpm.yaml> [--format deb|rpm|apk|arch] [-o linuxpkg.json]
linuxpkg verify  <package|repository dir> [--keyring KEY]
linuxpkg repo   <dir> [--format deb|rpm|all] [--sign-key KEY]
linuxpkg key apk-pub|info <private key> [--name NAME] [--out DIR]
linuxpkg init [PATH] [--force]
```

`repo` writes apt and dnf repository metadata for the packages in a directory, see [repository.md](repository.md).
`--sign-key`, `--keyring` and `key` are explained in [signing.md](signing.md).

Exit status: `0` success; `1` usage error, unreadable file, not a package, or unsupported compression (bzip2);
`2` `verify` found a damaged or tampered package.

Output names: `name_version-release_arch.deb`, `name-version-release.arch.rpm` and `name-version-release-arch.pkg.tar.zst`
(the epoch is not part of the deb and rpm file names; Arch Linux names include it as `name-epoch:version-...`).

`--format all` (the default) writes the deb, the rpm, the Arch Linux package and the Alpine package
(`name-version-r<release>.apk`). A package that does not fit Arch Linux or Alpine (architecture without a port, release
that is not a number, an epoch for Alpine) is skipped with a note; `--format arch` and `--format apk` report the reason as
an error. Alpine packages are always gzip, so `compression` does not apply to them. Arch Linux packages default to zstd like makepkg, the other formats to gzip.
