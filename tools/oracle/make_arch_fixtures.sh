#!/bin/bash
# Regenerates arch/fixtures_test.mbt with a package built by the real makepkg:
# the `which` package from the Arch Linux core repository (zstd, with a
# .BUILDINFO, a .MTREE and files with different modes).
# Usage: tools/oracle/make_arch_fixtures.sh [output-file]
set -e
OUT="${1:-arch/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
M=https://geo.mirror.pkgbuild.com/core/os/x86_64
NAME=$(curl -fsS "$M/" | grep -o 'href="which-[0-9][^"]*-x86_64\.pkg\.tar\.zst"' | sed 's/href="//; s/"$//' | tail -n 1)
curl -fsS -o "$NAME" "$M/$NAME"
python3 - "$OUT" "$NAME" <<'PY'
import sys, binascii
data = open(sys.argv[2], 'rb').read()
hexed = binascii.hexlify(data).decode()
out = []
out.append('///|')
out.append('/// `%s` from the Arch Linux core repository, built by makepkg.' % sys.argv[2])
out.append('/// Regenerate it with tools/oracle/make_arch_fixtures.sh.')
out.append('')
out.append('///|')
out.append('let real_which_package : String =')
for i in range(0, len(hexed), 96):
    out.append('  #|' + hexed[i:i + 96])
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
echo "wrote $OUT from $NAME"
zstd -dc "$NAME" | tar -t | head -20
rm -rf "$W"
