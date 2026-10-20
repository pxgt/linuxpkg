#!/bin/bash
# Regenerates compress/fixtures_test.mbt: one text compressed by the real xz,
# zstd and gzip tools (several levels, check types and stream layouts), so the
# decoders are tested against output they did not write themselves.
# Usage: tools/oracle/make_compress_fixtures.sh [output-file]
set -e
OUT="${1:-compress/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
python3 - <<'PY'
# A text that repeats, with a little variation, so every coder has work to do.
lines = []
for i in range(400):
    lines.append("line %d: the quick brown fox jumps over the lazy dog %d\n" % (i, i * i % 97))
open("plain.txt", "w", newline="\n").write("".join(lines))
PY
xz -6 -k -c plain.txt > plain.xz
xz -9e --check=crc32 -c plain.txt > plain_crc32.xz
xz --check=sha256 -c plain.txt > plain_sha256.xz
xz --check=none -c plain.txt > plain_none.xz
xz --format=lzma -c plain.txt > plain.lzma
# Two streams in a row, and a stream with a block per 4 KiB.
cat plain.xz plain.xz > plain_twice.xz
xz --block-size=4096 -c plain.txt > plain_blocks.xz
zstd -3 -q -c plain.txt > plain.zst
zstd -19 -q -c plain.txt > plain_19.zst
zstd -1 -q --no-check -c plain.txt > plain_nocheck.zst
# Streaming input has no content size in the frame header.
cat plain.txt | zstd -q -c > plain_stream.zst
gzip -9 -n -c plain.txt > plain.gz
python3 - "$OUT" "$(xz --version | head -n 1)" "$(zstd --version)" <<'PY'
import sys, binascii
out = []
out.append('///|')
out.append('/// Streams written by the real tools (%s; %s).' % (sys.argv[2], sys.argv[3]))
out.append('/// `plain_text()` is the text they all unpack to.')
out.append('/// Regenerate them with tools/oracle/make_compress_fixtures.sh.')
text = open('plain.txt', 'rb').read()
out.append('')
out.append('///|')
out.append('fn plain_text() -> String {')
out.append('  let lines : Array[String] = []')
out.append('  for i in 0..<400 {')
out.append('    lines.push("line \\{i}: the quick brown fox jumps over the lazy dog \\{i * i % 97}\\n")')
out.append('  }')
out.append('  lines.join("")')
out.append('}')
for name, path in (
    ('xz_default', 'plain.xz'), ('xz_crc32', 'plain_crc32.xz'),
    ('xz_sha256', 'plain_sha256.xz'), ('xz_nocheck', 'plain_none.xz'),
    ('xz_twice', 'plain_twice.xz'), ('xz_blocks', 'plain_blocks.xz'),
    ('lzma_alone', 'plain.lzma'),
    ('zstd_3', 'plain.zst'), ('zstd_19', 'plain_19.zst'),
    ('zstd_nocheck', 'plain_nocheck.zst'), ('zstd_stream', 'plain_stream.zst'),
    ('gzip_9', 'plain.gz'),
):
    data = open(path, 'rb').read()
    hexed = binascii.hexlify(data).decode()
    out.append('')
    out.append('///|')
    out.append('let %s : String =' % name)
    for i in range(0, len(hexed), 96):
        out.append('  #|' + hexed[i:i + 96])
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
echo "wrote $OUT"
ls -l plain.txt plain*.xz plain.lzma plain*.zst plain.gz
rm -rf "$W"
