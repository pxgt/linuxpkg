#!/usr/bin/env bash
# Builds the signed package repositories that GitHub Pages serves.
#
# Usage: tools/assemble_site.sh <linuxpkg binary> <directory with the packages> <output directory> <signing key>
#
# The packages directory has one subdirectory per CPU architecture (x86_64, aarch64), each with the
# deb, rpm, Arch (.pkg.tar.zst with its .sig) and Alpine (.apk) packages built for it (Alpine file
# names carry no architecture, hence the separate directories). The output gets
#   apt/            flat apt repository with InRelease and Release.gpg
#   rpm/            dnf repository (repodata with repomd.xml.asc) and linuxpkg.repo
#   arch/<arch>/    pacman database linuxpkg.db with signatures, one directory per architecture
#   alpine/<arch>/  APKINDEX.tar.gz with signature, one directory per architecture
# The signing key is read from the file and never printed.
set -euo pipefail

BIN="$1"
PKGS="$2"
OUT="$3"
KEY="$4"
BASE="${SITE_URL:-https://pxgt.github.io/linuxpkg}"

step() { printf '\n==> %s\n' "$*"; }

mkdir -p "$OUT/apt" "$OUT/rpm" "$OUT/alpine" "$OUT/arch"

ARCHES=()
for arch in x86_64 aarch64; do
  if [ -d "$PKGS/$arch" ]; then ARCHES+=("$arch"); fi
done
[ "${#ARCHES[@]}" -gt 0 ] || { echo "no package directories in $PKGS" >&2; exit 1; }

step "apt"
for arch in "${ARCHES[@]}"; do cp "$PKGS/$arch"/*.deb "$OUT/apt/"; done
"$BIN" repo "$OUT/apt" --format deb --sign-key "$KEY"

step "dnf"
for arch in "${ARCHES[@]}"; do cp "$PKGS/$arch"/*.rpm "$OUT/rpm/"; done
"$BIN" repo "$OUT/rpm" --format rpm --sign-key "$KEY"
cat >"$OUT/rpm/linuxpkg.repo" <<EOF
[linuxpkg]
name=linuxpkg
baseurl=$BASE/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$BASE/linuxpkg.asc
EOF

step "pacman"
for arch in "${ARCHES[@]}"; do
  mkdir -p "$OUT/arch/$arch"
  cp "$PKGS/$arch"/*.pkg.tar.zst "$PKGS/$arch"/*.pkg.tar.zst.sig "$OUT/arch/$arch/"
  "$BIN" repo "$OUT/arch/$arch" --format arch --name linuxpkg --sign-key "$KEY"
done

step "apk"
for arch in "${ARCHES[@]}"; do
  tmp="$(mktemp -d)"
  cp "$PKGS/$arch"/*.apk "$tmp/"
  "$BIN" repo "$tmp" --format apk --name linuxpkg --sign-key "$KEY" --apk-key-name linuxpkg.rsa.pub
  mkdir -p "$OUT/alpine"
  cp -r "$tmp/$arch" "$OUT/alpine/$arch"
  rm -rf "$tmp"
done

touch "$OUT/.nojekyll"
find "$OUT" -type f | sort | sed "s#^$OUT/##"
