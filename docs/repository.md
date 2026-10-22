# Package repositories (`linuxpkg repo`)

A directory of packages becomes an installable repository once it has index files next to the packages.
`linuxpkg repo <dir>` writes them; after that `apt install`, `dnf install`, `pacman -S` and `apk add` work against the
directory (or any web server that serves it).

```sh
linuxpkg build linuxpkg.json --out repo           # repo/hello_1.0.0-1_all.deb, repo/hello-1.0.0-1.noarch.rpm
linuxpkg repo repo                                # every kind found   (--format deb | rpm | arch | apk | all)
```

The command reads every `*.deb`, `*.rpm`, `*.pkg.tar.*` and `*.apk` directly inside `<dir>` (no subdirectories), writes the indexes, and then
checks them against the packages again (hashes, sizes, one entry per package). It stops with an error if a file is not a
valid package or the index turns out to be inconsistent.

## apt: flat repository

Files written into `<dir>`:

| File | Content |
|---|---|
| `Packages` | the `control` paragraph of every deb, followed by `Filename: ./<name>`, `Size`, `MD5sum`, `SHA1`, `SHA256` |
| `Packages.gz`, `Packages.xz` | the same, compressed |
| `Release` | `Date`, `Architectures`, and the `MD5Sum`, `SHA1` and `SHA256` of the three files above |

Use it with a source line (for a local directory or `http://host/path/`):

```
deb [trusted=yes] file:/srv/repo ./
```

The packages are listed in file name order and the control paragraphs are copied unchanged, so the result is
reproducible. `Packages` carries the same fields and values as `apt-ftparchive packages .` (which orders the fields in
its own way and adds `SHA512`); the oracle script compares them.

## dnf / yum: repodata

Files written into `<dir>/repodata/`, named like createrepo's output (`<sha256>-primary.xml.gz`):

| File | Content |
|---|---|
| `repomd.xml` | for `primary`, `filelists` and `other`: `checksum` and `size` (compressed), `open-checksum` and `open-size`, `location`, `timestamp`; plus `revision` |
| `*-primary.xml.gz` | per package: name, arch, `epoch/ver/rel`, checksum (`pkgid`), summary, description, packager, url, times, sizes, `location`, `format` (license, vendor, group, buildhost, sourcerpm, `header-range`, provides, requires, conflicts, obsoletes, suggests, recommends, and the files createrepo lists in primary) |
| `*-filelists.xml.gz` | all files of each package; directories have `type="dir"` |
| `*-other.xml.gz` | the ten newest changelog entries of each package |

A `.repo` file for the directory:

```ini
[linuxpkg]
name=linuxpkg
baseurl=file:///srv/repo
enabled=1
gpgcheck=0
```

`filelists.xml` and `other.xml` of linuxpkg are identical to `createrepo_c`'s for the same packages; `primary.xml` is too,
with one difference: createrepo_c condenses the `libc.so.6(GLIBC_x.y)` requirements of a package to the newest one,
linuxpkg lists them all (dnf resolves both the same way). The comparison runs in `tools/oracle/run.sh`.

## pacman: database (Arch Linux)

`linuxpkg repo <dir> --format arch --name NAME` reads every `*.pkg.tar.*` in `<dir>` (and the `<package>.sig` files next
to them) and writes, as `repo-add` does:

| File | Content |
|---|---|
| `NAME.db.tar.gz`, `NAME.db` | a gzip tar with `<pkgname>-<pkgver>/desc` per package: `%FILENAME%`, `%NAME%`, `%BASE%`, `%VERSION%`, `%DESC%`, `%CSIZE%`, `%ISIZE%`, `%MD5SUM%`, `%SHA256SUM%`, `%PGPSIG%` (when a `.sig` exists), `%URL%`, `%LICENSE%`, `%ARCH%`, `%BUILDDATE%`, `%PACKAGER%`, `%REPLACES%`, `%CONFLICTS%`, `%PROVIDES%`, `%DEPENDS%`, `%OPTDEPENDS%` |
| `NAME.files.tar.gz`, `NAME.files` | the same plus a `files` list (`%FILES%`) per package |

`NAME.db` is a copy of `NAME.db.tar.gz`, not a link, because a static web server (GitHub Pages) has no symbolic links.
The default name is `linuxpkg`. In `/etc/pacman.conf`:

```
[NAME]
SigLevel = Optional TrustAll          # unsigned; or  Required DatabaseRequired  when signed
Server = file:///srv/repo             # or https://example.org/arch/$arch
```

## apk: Alpine repository

`linuxpkg repo <dir> --format apk` reads every `*.apk` in `<dir>` and writes, for each architecture, a directory with
the index and the packages (apk looks for them next to the index):

```
<dir>/x86_64/APKINDEX.tar.gz      DESCRIPTION and APKINDEX, as `apk index` writes them
<dir>/x86_64/hello-1.0.0-r1.apk
<dir>/noarch/hello-1.0.0-r1.apk   architecture independent packages are fetched from noarch/
```

`noarch` packages are listed in the index of every architecture directory that exists; if there are only `noarch`
packages, the directories of `x86_64` and `aarch64` are made. Use it with `apk --repository <dir> add ...` (an unsigned
index needs `--allow-untrusted`).

## Dates

`Release` and `repomd.xml` need a date. It is `SOURCE_DATE_EPOCH` if that variable is set, otherwise the newest
modification time found in the packages (deb file entries, rpm build time). Running the command again on the same
directory therefore rewrites identical files.

## Signing

`linuxpkg repo <dir> --sign-key KEY` signs the indexes with an OpenPGP private key (RSA or Ed25519, armored or
binary, no passphrase; see [signing.md](signing.md)):

| Written next to the indexes | What it is |
|---|---|
| `InRelease` | `Release` as a cleartext-signed message (what current apt reads first) |
| `Release.gpg` | armored detached signature over the exact bytes of `Release` |
| `repodata/repomd.xml.asc` | armored detached signature over the exact bytes of `repodata/repomd.xml` |

The signature time is the repository date (`SOURCE_DATE_EPOCH` or the packages' newest time), but never earlier than the
key itself, so running the command again writes identical files. After signing, the command reads the signatures back
and checks them with the key.

```sh
linuxpkg repo repo --sign-key release.key.asc
# users add the public key and the source; no [trusted=yes]:
#   deb [signed-by=/etc/apt/keyrings/example.asc] https://example.org/repo ./
# dnf: in the .repo file   repo_gpgcheck=1   gpgkey=https://example.org/example.asc
```

Check a repository with `linuxpkg verify <dir> --keyring PUBLICKEY`; the exit status is 2 if a signature is missing or
does not match. The signatures are checked in CI with `gpgv`, with apt (`signed-by`) and dnf (`repo_gpgcheck=1`) in
Debian, Ubuntu, Fedora and openEuler containers, and a repository changed after signing is refused by all of them.

For pacman the databases get `NAME.db.sig`, `NAME.db.tar.gz.sig` and the same for `.files`; with
`SigLevel = Required DatabaseRequired` pacman also demands the signatures of the packages (build them with
`--sign-key`). For Alpine, `--sign-key` (RSA only) puts the signature in front of every `APKINDEX.tar.gz` as `abuild-sign` does; `--apk-key-name` names
the public key that users keep in `/etc/apk/keys/`.

Signing the rpm packages themselves (`gpgcheck=1`) is `build --sign-key`; Debian packages are not signed one by one
(the repository's `Release` file carries the trust), see [signing.md](signing.md).

## As a library

`Xpeng/linuxpkg/repo` works on bytes, like the other packages: `apt_index(debs, date~)`, `yum_index(rpms, timestamp~)`, `arch_index(pkgs, sigs, name~, date~)` and
`apk_index(apks, description~, date~)` return the files to write as `(relative path, content)` pairs; `check_apt`, `check_yum`, `check_arch` and `check_apk` (and `check_*_signature`, `sign_*`) return the problems found
when comparing such files with the packages.
