#!/bin/bash
# Regenerates apk/fixtures_test.mbt with a package written by the real abuild of Alpine Linux v3.20
# from our own files (tools/oracle/fixture-src): three gzip streams, an RSA signature, PAX checksum
# records and the datahash. Nothing third-party is packaged. The package is signed with a key made
# for the occasion; the private half is thrown away and the public half goes into the fixture file.
#
# Usage: tools/oracle/make_apk_fixtures.sh [output-file]
# Needs docker (it runs alpine:3.20), or root and ALPINE_ROOT=<dir>: an Alpine v3.20 root made with
#   apk.static -X https://dl-cdn.alpinelinux.org/alpine/v3.20/main -U --allow-untrusted \
#     --root <dir> --initdb add alpine-base abuild
# into which the script chroots.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-apk/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/src/fixtures" "$W/out"
cp -r "$HERE/fixture-src/apk/fixtures/linuxpkg-fixture" "$W/src/fixtures/"
cp "$HERE/fixture-src/common/linuxpkg-fixture.sh" "$HERE/fixture-src/common/linuxpkg-fixture.conf" \
  "$HERE/fixture-src/common/README" "$HERE/fixture-src/common/linuxpkg-fixture.post-install" \
  "$W/src/fixtures/linuxpkg-fixture/"
cat >"$W/build.sh" <<'EOF'
set -e
command -v abuild >/dev/null || apk add --no-cache abuild >/dev/null
export PACKAGER="pxgt <133531533+pxgt@users.noreply.github.com>"
export SOURCE_DATE_EPOCH=1700000000
mkdir -p /root/.abuild
openssl genrsa -out /root/.abuild/linuxpkg-test-only.rsa 2048 2>/dev/null
openssl rsa -in /root/.abuild/linuxpkg-test-only.rsa -pubout -out /root/.abuild/linuxpkg-test-only.rsa.pub 2>/dev/null
echo 'PACKAGER_PRIVKEY="/root/.abuild/linuxpkg-test-only.rsa"' >/root/.abuild/abuild.conf
cp /root/.abuild/linuxpkg-test-only.rsa.pub /etc/apk/keys/
cd /work/src/fixtures/linuxpkg-fixture
abuild -F checksum
abuild -F -d -P /work/out
cp /root/.abuild/linuxpkg-test-only.rsa.pub /work/out/
apk info -e -v abuild >/work/out/abuild-version
rm -f /root/.abuild/linuxpkg-test-only.rsa /etc/apk/keys/linuxpkg-test-only.rsa.pub
EOF
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm -v "$W:/work" alpine:3.20 sh /work/build.sh
elif [ -n "${ALPINE_ROOT:-}" ]; then
  mkdir -p "$ALPINE_ROOT/work"
  mount --bind "$W" "$ALPINE_ROOT/work"
  mount -t proc proc "$ALPINE_ROOT/proc"
  mount --bind /dev "$ALPINE_ROOT/dev"
  cp /etc/resolv.conf "$ALPINE_ROOT/etc/resolv.conf"
  status=0
  chroot "$ALPINE_ROOT" /bin/sh /work/build.sh || status=$?
  umount "$ALPINE_ROOT/work" "$ALPINE_ROOT/proc" "$ALPINE_ROOT/dev"
  [ "$status" -eq 0 ] || exit "$status"
else
  echo "make_apk_fixtures.sh needs docker, or root with ALPINE_ROOT set" >&2
  exit 1
fi
PKG="$(find "$W/out" -name 'linuxpkg-fixture-*.apk' | head -n 1)"
[ -n "$PKG" ] || { echo "abuild wrote no package" >&2; exit 1; }
python3 - "$OUT" "$PKG" "$W/out/linuxpkg-test-only.rsa.pub" "$(cat "$W/out/abuild-version")" <<'PY'
import binascii, os, sys
out, pkg, pub, version = sys.argv[1:5]
data = open(pkg, "rb").read()
hexed = binascii.hexlify(data).decode()
lines = [
    "///|",
    "/// `%s`, written by the real abuild (%s, Alpine Linux v3.20) from" % (os.path.basename(pkg), version),
    "/// tools/oracle/fixture-src: files written for linuxpkg (Apache-2.0), nothing third-party.",
    "/// Signed with a throw-away test-only key; `abuild_test_key` is its public half.",
    "/// Regenerate both with tools/oracle/make_apk_fixtures.sh.",
    "let real_abuild_package : String =",
]
for i in range(0, len(hexed), 96):
    lines.append("  #|" + hexed[i:i + 96])
lines += ["", "///|", "/// Public half of the test-only key that signed `real_abuild_package`.", "let abuild_test_key : String ="]
for line in open(pub).read().splitlines():
    lines.append("  #|" + line)
open(out, "w", newline="\n").write("\n".join(lines) + "\n")
PY
echo "wrote $OUT from $(basename "$PKG")"
