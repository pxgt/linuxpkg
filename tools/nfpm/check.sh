#!/bin/sh
# Builds the nFPM configurations of testdata/nfpm with the real nFPM and with linuxpkg and compares the
# packages (dpkg-deb, rpm, tar). Needs dpkg-deb, rpm, tar with zstd, python3, curl and sha256sum.
#
# usage: tools/nfpm/check.sh LINUXPKG [compare.py options]
set -eu
NFPM_VERSION=2.48.0
BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

base="https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}"
tarball="nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz"
curl -fsSL -o "$WORK/$tarball" "$base/$tarball"
curl -fsSL -o "$WORK/checksums.txt" "$base/checksums.txt"
(cd "$WORK" && grep -F " $tarball" checksums.txt | grep -v sbom | sha256sum -c -)
tar -xzf "$WORK/$tarball" -C "$WORK" nfpm
"$WORK/nfpm" --version | grep -m1 GitVersion

python3 tools/nfpm/compare.py "$WORK/nfpm" "$BIN" testdata/nfpm/configs testdata/nfpm/tree --expect tools/nfpm/expected.txt "$@"
