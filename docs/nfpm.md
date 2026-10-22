# Using an nFPM configuration (`nfpm.yaml`)

[nFPM](https://nfpm.goreleaser.com/) (Go, MIT) is the most used tool of this kind. linuxpkg reads its configuration file, so
a project that builds packages with nFPM can try linuxpkg without rewriting anything:

```
linuxpkg build nfpm.yaml --out dist                    # deb, rpm, Arch Linux and Alpine packages
linuxpkg build nfpm.yaml --format deb                  # one packager
linuxpkg convert nfpm.yaml -o linuxpkg.json            # the same as a linuxpkg.json
linuxpkg convert nfpm.yaml --format rpm                # with the overrides of the rpm packager applied
```

A file ending in `.yaml` or `.yml` is read as an nFPM configuration. Everything linuxpkg cannot do is **named on standard
error** and the build goes on; a field that does not exist is an error, like in nFPM (`KnownFields(true)`). Nothing is
dropped silently.

## How it differs from nFPM on purpose

* **One packager at a time.** nFPM's `overrides` and `packager:` filters differ for every format, so `build` converts the file once
  for each of deb, rpm, apk and archlinux. If one of them cannot be built (for example an alternative dependency in the deb
  override) the other ones are still written and the exit status is 1.
* **Paths are relative to the current directory**, like nFPM, not to the configuration file (`linuxpkg.json` files are relative to
  themselves).
* **File modes.** nFPM copies the mode of the source file. linuxpkg cannot ask the file system for it on every platform, so a file
  without `file_info.mode` is `0755` when it starts with `#!` or is an ELF file and `0644` otherwise. Write `file_info.mode` for
  anything else.
* **Release.** linuxpkg always writes a release (`-1`); nFPM leaves it out when `release` is not set. For Alpine and Arch Linux
  the release must be a number.
* **Pre-releases.** `v1.2.3-rc.1+git` is split like nFPM does (Masterminds semver) and written as `1.2.3~rc.1+git`; a `-` in a
  pre-release becomes `.`.
* **Numbers stay text.** nFPM (Go) keeps `version: 1.10` and reads `mode: 0755` as octal. The YAML reader of linuxpkg follows YAML
  1.2 and would turn them into `1.1` and `755`, so the values of `version`, `release`, `epoch`, `prerelease`, `version_metadata` and
  `mode` are put in quotes before reading (not inside block scalars and comments). `mode` is octal: `0755`, `755`, `0o755`.
* **`mtime`** is a timestamp (`2024-01-31T12:00:00Z`); without it the build time is `SOURCE_DATE_EPOCH` (nFPM: the clock).
* **Environment variables** are expanded in the same fields as nFPM does it with the same rules as Go's `os.Expand`: `name`,
  `version`, `release`, `prerelease`, `platform`, `arch`, `homepage`, `maintainer`, `vendor`, `description`, the lists of relations (items
  are trimmed, empty ones dropped), `contents[].src` and `dst` when `expand: true`, signature `key_file` and `key_id`. `$VAR` and
  `${VAR}`; an unset variable is empty; there is no `${VAR:-default}`; `$1`, `$$` and the like are one-character names. Not
  expanded: `license`, `section`, `priority`, script paths.
* **ELF files** are checked against the architecture like for every configuration (see [config.md](config.md)); nFPM does not
  look. `--allow-arch-mismatch` switches it off.

## Compatibility

✅ same result, ⚠️ works with a difference, ❌ not supported (a warning names it; `✋` means it is an error).

| nFPM | | Notes |
|---|---|---|
| `name`, `homepage`, `license`, `vendor`, `description` | ✅ | `description` defaults to "no description given" like nFPM. |
| `maintainer` | ⚠️ | linuxpkg needs one: if it is empty `Unknown <unknown@example.invalid>` is used, with a warning. |
| `arch` | ✅ | `386`→i386, `arm5`→armel, `arm6`/`arm7`→armhf, `s390`→s390x, `amd64`, `arm64`, `ppc64le`, `riscv64`, `loong64`, `mips64le`, `all`; left out: amd64. `mips`, `mipsle` and others: ✋ error. |
| `platform` | ✅ | `linux` or empty; another value: ✋ error. |
| `version`, `prerelease`, `version_metadata`, `version_schema` | ✅ | Split as nFPM does; see above. |
| `release` | ⚠️ | Always written (default `1`). |
| `epoch` | ✅ | Not for apk (no such thing; ignored with a warning). |
| `section`, `priority` | ✅ | deb fields. nFPM leaves Section empty when not set, linuxpkg writes `misc`. |
| `mtime` | ✅ | See above. |
| `disable_globbing` | ✅ | |
| `changelog` | ❌ | No changelog files are written. |
| `umask` | ❌ | Not used; see "file modes". |
| `depends`, `recommends`, `suggests`, `conflicts`, `replaces`, `provides` | ✅ | `name (>= 1.2)` style. Alternatives (`a \| b`, `(a or b)`) and rich dependencies: ✋ error, write one entry per package. |
| `contents[].src`, `dst` | ✅ | |
| `type: ""`, `file`, `config`, `dir`, `symlink` | ✅ | |
| `type: config\|noreplace` | ⚠️ | A configuration file; in rpm it is `%config`, nFPM writes `%config(noreplace)`. |
| `type: config\|missingok` | ⚠️ | A configuration file, "missingok" is lost. |
| `type: tree`, `config\|tree`, `config\|noreplace\|tree` | ⚠️ | The directory is walked; symbolic links inside it are installed as copies of their targets. |
| `type: ghost` | ❌ | The entry is left out. |
| `type: doc`, `license`, `licence`, `readme` | ⚠️ | Plain file in rpm (the flag is lost); left out of the other formats like nFPM does. |
| `src` with `*`, `**`, `?`, `[a-z]` | ✅ | Same rules for the destination as nFPM (see below). `{a,b}`: ✋ error (no match). |
| `packager` | ✅ | |
| `file_info.mode`, `owner`, `group`, `mtime` | ✅ | |
| `file_info.lang`, `disown_subtree` | ❌ | |
| `expand` | ✅ | |
| `scripts.preinstall`, `postinstall`, `preremove`, `postremove` | ✅ | |
| `overrides` for `deb`, `rpm`, `apk`, `archlinux` | ✅ | Merged like nFPM does (mergo): unset values change nothing, lists replace. `ipk`, `msix`: ignored with a warning. |
| `deb.compression` | ✅ | `none`, `gzip`, `xz`, `zstd`. |
| `deb.arch` | ✅ | |
| `deb.fields`, `deb.triggers`, `deb.breaks`, `deb.predepends`, `deb.arch_variant`, `deb.scripts.rules`/`templates`/`config` | ❌ | |
| `deb.signature` | ⚠️ | A deb is not signed by itself; sign the repository (`linuxpkg repo --sign-key`). |
| `rpm.compression` | ✅ | `gzip`, `xz`, `zstd`; `lzma`: ✋ error. |
| `rpm.arch`, `rpm.group` | ✅ | The group is written as the rpm Group (linuxpkg: `section`). |
| `rpm.summary`, `buildhost`, `packager`, `prefixes`, `scripts.pretrans`/`posttrans`/`verify`, `requires.post` | ❌ | |
| `rpm.signature.key_file`, `apk.signature.key_file`, `apk.signature.key_name` | ✅ | One key signs rpm, Arch Linux and apk (`sign_key`); a key with a passphrase (`NFPM_PASSPHRASE`) is not supported. `key_id`: ❌. |
| `apk.arch`, `archlinux.arch` | ✅ | |
| `apk.scripts`, `archlinux.scripts` (`preupgrade`, `postupgrade`) | ❌ | |
| `archlinux.pkgbase`, `archlinux.packager` | ❌ | |
| `ipk`, `msix` | ❌ | These formats are not built. |

The destination of a file from a pattern follows nFPM: with a `dst` that ends in `/` every file goes directly into that directory;
otherwise it goes to `dst` plus its path relative to the directory the pattern starts in (the parent of the longest common prefix of
the matches). Matches are searched below the part of the pattern without special characters, a matched directory brings its
contents, and `a/**/b` needs at least one directory between `a` and `b` (as in nFPM's glob library).

## How this was checked

The 38 acceptance configurations of nFPM v2.48.0 (`testdata/acceptance/*.yaml`, MIT, copied unchanged to
[`testdata/nfpm/configs`](../testdata/nfpm/configs); the nFPM-only formats ipk and msix, source rpms and signing are left out, 29 files)
were built with the real nFPM and with linuxpkg for deb, rpm, apk and Arch Linux, and the packages were read back with `dpkg-deb`,
`rpm` and `tar`: fields, relations, files with mode, owner and link target, and flags. `tools/nfpm/check.sh` (CI, `oracle` job) downloads
nFPM, checks its checksum and runs `tools/nfpm/compare.py`. The two programs are independent, so the packages are not byte for byte
equal; the comparison lists every difference and **fails on any that is not in
[`tools/nfpm/expected.txt`](../tools/nfpm/expected.txt)** (and on an entry there that stopped being true). Result of the 116 package
pairs: 105 are built by both and differ only in the explained ways below, 11 are built by nFPM only (alternative dependencies,
ELF check, `lzma`, non-numeric release for Alpine and Arch Linux).

| What differs | Formats | Why |
|---|---|---|
| `Section` (empty / `misc`), `Version` (no revision / `-1`) | deb | See "release" and `section` above. |
| `Group`, `License` when not set | rpm | linuxpkg writes `misc` and `Unspecified`. |
| `name(x86-64) = version` provide | rpm | nFPM and rpmbuild add it, linuxpkg does not. |
| `%config` instead of `%config(noreplace)` | rpm | `config\|noreplace` is not told apart from `config`. |
| `Breaks`, `Pre-Depends`, `Requires(post)` | deb, rpm | Not supported, named by a warning. |
| mode of a symbolic link (`l---------` / `lrwxrwxrwx`) | deb, rpm, apk, Arch | nFPM stores 0; dpkg, rpmbuild and linuxpkg 0777. |
| changelog files | deb | `changelog:` is not supported. |
| `maintainer` / `packager` / `origin`, `pkgver` with release | apk | Different fields in `.PKGINFO`. |
| `packager`, `pkgdesc` (whole text / first line), `pkgver` of pre-releases, `xdata = pkgtype=pkg` | Arch | nFPM writes "Unknown Packager" and no `pkgtype`; linuxpkg follows `makepkg`. |

## Reading the code

`nfpm/` is a package of its own (`@nfpm.convert`) that turns the text of an nFPM file into a `linuxpkg.json` JSON value plus the
warnings, with no file system of its own: a `Host` gives it environment variables, files and directory listings. The command line
supplies the real ones. YAML is read by [`moonbitstack/moonyaml`](https://mooncakes.io/docs/moonbitstack/moonyaml) (YAML 1.2.2); the
38 configurations above give the same data as PyYAML, apart from the octal numbers described above.
