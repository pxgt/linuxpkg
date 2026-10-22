# Tutorial: from a MoonBit program to apt, dnf, pacman and apk in five minutes

This walks through publishing a MoonBit command line program so that people can install it with their distribution's
package manager. You need the MoonBit toolchain and the linuxpkg binary (from a release, or
`moonx Xpeng/linuxpkg/cmd/main`). Everything below also works on Windows and macOS, because linuxpkg writes the packages itself.

## 1. Build the program

```sh
moon build --target native --release
```

The executable ends up in `_build/native/release/build/cmd/main/main.exe` (or the package directory of your own
`pkgtype(kind: "executable")` package). A *static* binary runs on every distribution, Alpine included; on Linux add
`options(link: { "native": { "cc-link-flags": "-static" } })` to that package's `moon.pkg` for the release build.

## 2. Write the configuration

```sh
linuxpkg init --moon .
```

This reads `moon.mod`, finds the executable package and writes a `linuxpkg.json` that installs the binary as
`/usr/bin/<name>` together with the README and the licence. Open it and set `"maintainer"`; add dependencies, a
configuration file or a systemd unit if you need them (see [config.md](config.md)).

## 3. Build all four formats

```sh
linuxpkg build linuxpkg.json --out dist
# dist/myapp_0.1.0-1_amd64.deb  myapp-0.1.0-1.x86_64.rpm  myapp-0.1.0-1-x86_64.pkg.tar.zst  myapp-0.1.0-r1.apk
linuxpkg verify dist/myapp_0.1.0-1_amd64.deb    # checksums of everything inside
```

The same input always gives the same bytes; set `SOURCE_DATE_EPOCH` (or `"mtime"`) to pin the dates.

## 4. Sign

Make a signing key once (any OpenPGP tool; no passphrase for a key that CI uses):

```sh
gpg --quick-generate-key "myapp releases" rsa3072 sign never
gpg --armor --export-secret-keys "myapp releases" > release.key     # keep this secret
gpg --armor --export "myapp releases" > release.pub.asc             # publish this
```

```sh
linuxpkg build linuxpkg.json --out dist --sign-key release.key --apk-key-name myapp.rsa.pub
linuxpkg key apk-pub release.key --name myapp --out dist           # myapp.rsa.pub for Alpine
linuxpkg verify dist/myapp-0.1.0-1.x86_64.rpm --keyring release.pub.asc
```

## 5. Make the repositories and publish them

Put the packages in one directory and generate the indexes, signed with the same key:

```sh
linuxpkg repo dist --sign-key release.key --name myapp --apk-key-name myapp.rsa.pub
```

Serve `dist/` from any static web server or GitHub Pages ([how this project does it](../.github/workflows/pages.yml)).
Your users then add the source and your public key:

```sh
# Debian, Ubuntu
curl -fsSL https://example.org/release.pub.asc | sudo tee /etc/apt/keyrings/myapp.asc
echo "deb [signed-by=/etc/apt/keyrings/myapp.asc] https://example.org/ ./" | sudo tee /etc/apt/sources.list.d/myapp.list
sudo apt update && sudo apt install myapp

# Fedora, openEuler: a .repo file with  baseurl=https://example.org/  gpgcheck=1  repo_gpgcheck=1  gpgkey=https://example.org/release.pub.asc
sudo dnf install myapp

# Arch: pacman-key --add release.pub.asc && pacman-key --lsign-key <fingerprint>, then a [myapp] section with
#   SigLevel = Required DatabaseRequired   and   Server = https://example.org/  (one directory per architecture if you publish several)
sudo pacman -Sy myapp

# Alpine: put myapp.rsa.pub in /etc/apk/keys/ and add https://example.org to /etc/apk/repositories (apk appends the architecture directory itself)
sudo apk add myapp
```

Details for each family are in [repository.md](repository.md); the signing formats are in [signing.md](signing.md).

## 6. Automate it

[github-action.md](github-action.md) shows a workflow that does steps 1–5 on every GitHub Release.
