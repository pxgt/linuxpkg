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
| `contents` | object array | `[]` | Files, directories and links, see below. |
| `scripts` | object | none | `preinstall`, `postinstall`, `preremove`, `postremove`: paths of script files; each must start with `#!` for deb. |
| `$schema` | string | ignored | For editors. |

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

Parent directories: debs list every parent directory automatically; rpms own only the directories you list.

## Command line

```
linuxpkg build <config.json> [--format deb|rpm|all] [--out DIR]
linuxpkg inspect <file.deb|file.rpm> [--json]
linuxpkg verify  <file.deb|file.rpm>
linuxpkg init [PATH] [--force]
```

Exit status: `0` success; `1` usage error, unreadable file, not a package, or unsupported compression;
`2` `verify` found a damaged or tampered package.

Output names: `name_version-release_arch.deb` and `name-version-release.arch.rpm` (the epoch is not part of file names).
