#!/usr/bin/env bash
# Measures time and peak memory of `linuxpkg build` on large inputs.
#
# Usage: tools/bench.sh [SIZE_MB ...]      (default: 50 200)
#
# Builds release binaries for native and wasm-gc, makes a tree of SIZE_MB megabytes (half text-like data,
# half random bytes, in 10 MB files), and builds the four formats with gzip (xz and zstd for the smaller
# size). For comparison it times `dpkg-deb --build` and `tar | gzip` on the same tree when they exist.
# Writes a table to stdout. Needs GNU time (/usr/bin/time) and python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SIZES=("$@")
if [ ${#SIZES[@]} -eq 0 ]; then SIZES=(50 200); fi
W="${BENCH_DIR:-/tmp/linuxpkg-bench}"
mkdir -p "$W"

moon build --target native --release cmd/main >/dev/null
moon build --target wasm-gc --release cmd/main >/dev/null
NATIVE="$(find "$ROOT/_build/native/release" -name main.exe -path '*cmd/main*' | head -n 1)"
WASM="$(find "$ROOT/_build/wasm-gc/release" -name main.wasm -path '*cmd/main*' | head -n 1)"
MOONRUN="$(command -v moonrun || echo "$HOME/.moon/bin/moonrun")"

measure() { # label, command...  -> prints "label seconds peakMB"
  local label="$1"; shift
  local out="$W/time.txt"
  /usr/bin/time -v -o "$out" "$@" >/dev/null 2>"$W/stderr.txt" || { echo "$label FAILED"; cat "$W/stderr.txt" | head -3; return; }
  local secs peak
  secs="$(awk -F': ' '/Elapsed \(wall clock\)/ {n=split($2,t,":"); s=0; for(i=1;i<=n;i++) s=s*60+t[i]; print s}' "$out")"
  peak="$(awk -F': ' '/Maximum resident set size/ {printf "%d", $2/1024}' "$out")"
  printf '%-34s %8.1f s %8d MB\n' "$label" "$secs" "$peak"
}

for size in "${SIZES[@]}"; do
  T="$W/tree-$size"
  if [ ! -d "$T" ]; then
    mkdir -p "$T"
    python3 - "$T" "$size" <<'PY'
import os, random, sys
root, mb = sys.argv[1], int(sys.argv[2])
rnd = random.Random(1)
words = ["alpha", "beta", "gamma", "delta", "usr/bin", "package", "0123456789", "linux", "lib", "share"]
chunk = 10 * 1024 * 1024
for i in range(mb // 10):
    if i % 2 == 0:
        parts, n = [], 0
        while n < chunk:
            w = rnd.choice(words) + " "
            parts.append(w); n += len(w)
        data = "".join(parts).encode()[:chunk]
    else:
        data = rnd.randbytes(chunk)
    open(os.path.join(root, "f%03d.bin" % i), "wb").write(data)
PY
  fi
  python3 - "$T" "$size" "$W/cfg-$size.json" <<'PY'
import json, os, sys
root, mb, out = sys.argv[1:4]
files = sorted(os.listdir(root))
cfg = {"name": "bench", "version": "1.0", "arch": "amd64", "maintainer": "B <b@example.org>",
       "description": "benchmark", "mtime": 1700000000,
       "contents": [{"src": os.path.join(root, f), "dst": "/opt/bench/" + f} for f in files]}
json.dump(cfg, open(out, "w"))
PY
  echo "== $size MB input =="
  comps=(gzip)
  if [ "$size" -le 50 ]; then comps=(gzip xz zstd); fi
  for c in "${comps[@]}"; do
    for fmt in deb rpm arch apk; do
      # xz and zstd cost the same in every format, so one format is enough
      if [ "$c" != gzip ] && [ "$fmt" != deb ]; then continue; fi
      measure "native $fmt $c" "$NATIVE" build "$W/cfg-$size.json" --format "$fmt" --compression "$c" --out "$W/out-native"
      measure "wasm-gc $fmt $c" "$MOONRUN" "$WASM" -- build "$W/cfg-$size.json" --format "$fmt" --compression "$c" --out "$W/out-wasm"
    done
  done
  if command -v dpkg-deb >/dev/null 2>&1; then
    mkdir -p "$W/dpkg-$size/DEBIAN" "$W/dpkg-$size/opt/bench"
    cp "$T"/* "$W/dpkg-$size/opt/bench/"
    printf 'Package: bench\nVersion: 1.0\nArchitecture: amd64\nMaintainer: B <b@example.org>\nDescription: benchmark\n' > "$W/dpkg-$size/DEBIAN/control"
    measure "dpkg-deb -Zgzip (reference)" dpkg-deb -Zgzip --build "$W/dpkg-$size" "$W/dpkg-$size.deb"
  fi
  measure "tar | gzip (reference)" bash -c "tar -C '$T' -cf - . | gzip -6 > '$W/ref-$size.tar.gz'"
  rm -rf "$W/out-native" "$W/out-wasm" "$W/dpkg-$size" "$W/dpkg-$size.deb" "$W/ref-$size.tar.gz"
done
