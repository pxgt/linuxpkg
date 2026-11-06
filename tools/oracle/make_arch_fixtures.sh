#!/bin/bash
# Regenerates arch/fixtures_test.mbt with a package written by the real makepkg of Arch Linux from
# our own files (tools/oracle/fixture-src): zstd, with a .BUILDINFO, a .MTREE, an .INSTALL, a backup
# file, a symbolic link and files with different modes. Nothing third-party is packaged.
#
# Usage: tools/oracle/make_arch_fixtures.sh [output-file]
# Needs docker (it runs archlinux:latest), or root and ARCH_ROOT=<dir>: an Arch Linux root, for
# example root.x86_64 from https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst
# with an initialised pacman keyring, into which the script chroots.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-arch/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/src" "$W/out"
cp "$HERE/fixture-src/arch/PKGBUILD" "$HERE/fixture-src/common/linuxpkg-fixture.sh" \
  "$HERE/fixture-src/common/linuxpkg-fixture.conf" "$HERE/fixture-src/common/README" \
  "$HERE/fixture-src/common/linuxpkg-fixture.install" "$W/src/"
cat >"$W/build.sh" <<'EOF'
set -e
pacman -Sy --noconfirm --needed fakeroot util-linux >/dev/null
id builder >/dev/null 2>&1 || useradd -m builder
rm -rf /home/builder/src && cp -r /work/src /home/builder/src && chown -R builder /home/builder/src
runuser -u builder -- env SOURCE_DATE_EPOCH=1700000000 \
  PACKAGER="pxgt <133531533+pxgt@users.noreply.github.com>" \
  bash -c 'cd /home/builder/src && makepkg --nodeps --force --noconfirm'
cp /home/builder/src/*.pkg.tar.zst /work/out/
runuser -u builder -- makepkg --version | head -n 1 >/work/out/makepkg-version
EOF
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm -v "$W:/work" archlinux:latest bash /work/build.sh
elif [ -n "${ARCH_ROOT:-}" ]; then
  mkdir -p "$ARCH_ROOT/work"
  mount --bind "$W" "$ARCH_ROOT/work"
  mount -t proc proc "$ARCH_ROOT/proc"
  mount --bind /dev "$ARCH_ROOT/dev"
  cp /etc/resolv.conf "$ARCH_ROOT/etc/resolv.conf"
  status=0
  chroot "$ARCH_ROOT" /bin/bash /work/build.sh || status=$?
  # pacman starts a gpg-agent that keeps /dev busy.
  chroot "$ARCH_ROOT" gpgconf --kill all >/dev/null 2>&1 || true
  for m in work proc dev; do umount "$ARCH_ROOT/$m" 2>/dev/null || umount -l "$ARCH_ROOT/$m"; done
  [ "$status" -eq 0 ] || exit "$status"
else
  echo "make_arch_fixtures.sh needs docker, or root with ARCH_ROOT set" >&2
  exit 1
fi
PKG="$(find "$W/out" -name 'linuxpkg-fixture-*.pkg.tar.zst' | head -n 1)"
[ -n "$PKG" ] || { echo "makepkg wrote no package" >&2; exit 1; }
python3 - "$OUT" "$PKG" "$(cat "$W/out/makepkg-version")" <<'PY'
import binascii, os, sys
out, pkg, version = sys.argv[1:4]
hexed = binascii.hexlify(open(pkg, "rb").read()).decode()
lines = [
    "///|",
    "/// `%s`, written by the real makepkg (%s) from" % (os.path.basename(pkg), version),
    "/// tools/oracle/fixture-src: files written for linuxpkg (Apache-2.0), nothing third-party.",
    "/// Regenerate it with tools/oracle/make_arch_fixtures.sh.",
    "let real_makepkg_package : String =",
]
for i in range(0, len(hexed), 96):
    lines.append("  #|" + hexed[i:i + 96])
open(out, "w", newline="\n").write("\n".join(lines) + "\n")
PY
echo "wrote $OUT from $(basename "$PKG")"
