#!/bin/bash
# Regenerates apk/fixtures_test.mbt with a package built by the real abuild:
# `tree` from the Alpine Linux v3.20 main repository (signed, three gzip
# streams, PAX checksum records).
# Usage: tools/oracle/make_apk_fixtures.sh [output-file]
set -e
OUT="${1:-apk/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
M=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.20/main/x86_64
curl -fsSL -o list.html "$M/"
NAME=$(grep -o 'href="tree-[0-9][^"]*\.apk"' list.html | sed 's/href="//; s/"$//' | tail -n 1)
curl -fsSL -o "$NAME" "$M/$NAME"
python3 - "$OUT" "$NAME" <<'PY'
import sys, binascii
data = open(sys.argv[2], 'rb').read()
hexed = binascii.hexlify(data).decode()
out = []
out.append('///|')
out.append('/// `%s` from the Alpine Linux v3.20 main repository, built by abuild.' % sys.argv[2])
out.append('/// Regenerate it with tools/oracle/make_apk_fixtures.sh.')
out.append('')
out.append('///|')
out.append('let real_tree_package : String =')
for i in range(0, len(hexed), 96):
    out.append('  #|' + hexed[i:i + 96])
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
echo "wrote $OUT from $NAME"
rm -rf "$W"
