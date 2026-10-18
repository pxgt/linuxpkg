#!/bin/bash
# Regenerates archive/tar/fixtures_test.mbt from GNU tar. Usage: tools/oracle/make_tar_fixtures.sh [output-file]
OUT="${1:-archive/tar/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
set -e
W=$(mktemp -d)
cd "$W"
mkdir -p a/usr
printf 'hi\n' > a/usr/hello
chmod 0644 a/usr/hello
printf '#!/bin/sh\n' > a/usr/run
chmod 0755 a/usr/run
ln -s hello a/usr/hi
chmod 0755 a/usr
(cd a && printf './usr/\n./usr/hello\n./usr/hi\n./usr/run\n' > ../list1)
(cd a && tar -b 1 --format=ustar --no-recursion --owner=root:0 --group=root:0 --mtime=@1700000000 -cf ../ref1.tar -T ../list1)

LONGDIR=$(printf 'd%.0s' $(seq 1 60))/$(printf 'e%.0s' $(seq 1 60))
mkdir -p "b/$LONGDIR"
printf 'x' > "b/$LONGDIR/file.txt"
chmod 0644 "b/$LONGDIR/file.txt"
(cd b && printf './%s/file.txt\n' "$LONGDIR" > ../list2)
(cd b && tar -b 1 --format=ustar --no-recursion --owner=root:0 --group=root:0 --mtime=@1700000000 -cf ../ref2.tar -T ../list2)

tar --version | head -1 > version.txt
python3 - "$OUT" <<'PY'
import sys, binascii, textwrap
version = open('version.txt').read().strip()

def encode(path):
    data = open(path, 'rb').read()
    tokens = []
    i = 0
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
    # wrap into lines of at most ~96 characters without splitting tokens
    lines, cur = [], ''
    for t in tokens:
        if cur and len(cur) + 1 + len(t) > 96:
            lines.append(cur)
            cur = t
        else:
            cur = (cur + ' ' + t) if cur else t
    if cur:
        lines.append(cur)
    return lines

out = []
out.append('///|')
out.append('/// Reference archives written by %s with' % version)
out.append('/// `tar -b 1 --format=ustar --no-recursion --owner=root:0 --group=root:0')
out.append('/// --mtime=@1700000000`. Runs of zero bytes are written as `Z<count>`, all other')
out.append('/// bytes as hex. Regenerate them with tools/oracle/make_tar_fixtures.sh.')
for name, path in (('ref_tree', 'ref1.tar'), ('ref_long_prefix', 'ref2.tar')):
    out.append('')
    out.append('///|')
    out.append('let %s : String =' % name)
    for line in encode(path):
        out.append('  #|' + line)
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
echo "LONG=$LONGDIR"
tar -tvf ref1.tar
tar -tvf ref2.tar
ls -l ref1.tar ref2.tar
rm -rf "$W"
