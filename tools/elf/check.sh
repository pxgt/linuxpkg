#!/bin/sh
# Checks the ELF support of linuxpkg against real tools and real binaries:
#  1. `linuxpkg elf` agrees with readelf on freshly cross-compiled programs, the committed samples
#     and some binaries of this machine;
#  2. `build` accepts a program in a package of its own architecture, refuses it in a package of
#     another one, warns for "all", and --allow-arch-mismatch overrides.
#
# usage: tools/elf/check.sh LINUXPKG     (needs readelf, python3 and the cross compilers listed in
# tools/elf/make_samples.sh; architectures without a compiler are skipped)
set -eu
BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> compile with the cross compilers"
sh tools/elf/make_samples.sh "$WORK/fresh"

echo "==> readelf and linuxpkg elf agree"
HOST_FILES="/bin/ls /bin/sh"
for f in /usr/bin/python3 /usr/bin/perl /lib/x86_64-linux-gnu/libc.so.6 /lib/aarch64-linux-gnu/libc.so.6; do
  [ -e "$f" ] && HOST_FILES="$HOST_FILES $f"
done
# shellcheck disable=SC2086
python3 tools/elf/compare_readelf.py "$BIN" "$WORK"/fresh/* testdata/elf/hello.* testdata/elf/tiny.* $HOST_FILES "$BIN"

echo "==> build checks"
ARCHS="amd64 arm64 i386 armhf armel ppc64le s390x riscv64 mips64le"
count=0
for arch in $ARCHS; do
  [ -f "$WORK/fresh/hello.$arch" ] || continue
  # The next architecture in the list is the wrong one.
  other="$(echo "$ARCHS" | tr ' ' '\n' | grep -A1 -x "$arch" | tail -n 1)"
  [ "$other" = "$arch" ] && other=amd64
  dir="$WORK/b-$arch"
  mkdir -p "$dir"
  cp "$WORK/fresh/hello.$arch" "$dir/hello"
  config() { # arch extra
    printf '{"name":"hello","version":"1","arch":"%s","maintainer":"J <j@example.org>","description":"Demo"%s,"contents":[{"src":"hello","dst":"/usr/bin/hello","mode":"0755"}]}' "$1" "$2"
  }
  config "$arch" "" > "$dir/right.json"
  config "$other" "" > "$dir/wrong.json"
  config all "" > "$dir/all.json"
  "$BIN" build "$dir/right.json" --out "$dir/out" >/dev/null || { echo "FAILED: $arch package for an $arch program was refused"; exit 1; }
  if "$BIN" build "$dir/wrong.json" --out "$dir/bad" 2>"$dir/err.txt"; then
    echo "FAILED: a $other package for an $arch program was accepted"; exit 1
  fi
  grep -q "ELF file for $arch" "$dir/err.txt" || { echo "FAILED: the error does not name $arch"; cat "$dir/err.txt"; exit 1; }
  [ ! -e "$dir/bad" ] || { echo "FAILED: files were written for a refused build"; exit 1; }
  "$BIN" build "$dir/wrong.json" --allow-arch-mismatch --out "$dir/forced" >/dev/null
  "$BIN" build "$dir/all.json" --out "$dir/all" 2>"$dir/warn.txt" >/dev/null
  grep -q "warning" "$dir/warn.txt" || { echo "FAILED: no warning for an ELF file in an all package"; exit 1; }
  # inspect shows the architecture the program is for.
  "$BIN" inspect "$dir/out/"*.deb | grep -q "ELF .* ($arch)" || { echo "FAILED: inspect does not show $arch"; exit 1; }
  echo "  $arch: ok (wrong: $other)"
  count=$((count + 1))
done
echo "all $count architectures behave"
