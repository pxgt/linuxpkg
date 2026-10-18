#!/bin/bash
# Regenerates archive/cpio/fixtures_test.mbt from GNU cpio.
# Usage: tools/oracle/make_cpio_fixtures.sh [output-file]
set -e
OUT="${1:-archive/cpio/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
mkdir -p a/usr
printf 'hi\n' > a/usr/hello
chmod 0644 a/usr/hello
printf '#!/bin/sh\n' > a/usr/run
chmod 0755 a/usr/run
ln -s hello a/usr/hi
chmod 0755 a/usr
find a -exec touch -h -d @1700000000 {} +
(cd a && printf './usr\n./usr/hello\n./usr/hi\n./usr/run\n' | cpio -o -H newc --reproducible --owner=0:0 --quiet > ../ref1.cpio)
CPIO_VERSION=$(cpio --version | head -n 1)
python3 - "$OUT" "$CPIO_VERSION" <<'PY'
import sys, binascii
data = open('ref1.cpio', 'rb').read()
tokens, i = [], 0
while i < len(data):
    j = i
    if data[i] == 0:
        while j < len(data) and data[j] == 0:
            j += 1
        tokens.append('Z%d' % (j - i))
    else:
        while j < len(data) and data[j] != 0:
            j += 1
        tokens.append(binascii.hexlify(data[i:j]).decode())
    i = j
lines, cur = [], ''
for t in tokens:
    if cur and len(cur) + 1 + len(t) > 96:
        lines.append(cur)
        cur = t
    else:
        cur = (cur + ' ' + t) if cur else t
if cur:
    lines.append(cur)
out = ['///|', '/// Reference archive written by %s with' % sys.argv[2],
       '/// `cpio -o -H newc --reproducible --owner=0:0`. Zero runs are written as `Z<count>`.',
       '/// Regenerate it with tools/oracle/make_cpio_fixtures.sh.', '', '///|',
       'let ref_tree : String =']
out += ['  #|' + l for l in lines]
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
cpio -itv --quiet < ref1.cpio
rm -rf "$W"
