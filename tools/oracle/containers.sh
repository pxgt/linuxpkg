#!/usr/bin/env bash
# Install the example packages in real distribution containers and run them,
# once for every payload compression, and read genuine distribution packages.
#
# Usage: tools/oracle/containers.sh [LINUXPKG_BINARY]
#
# Needs docker. Debian-family images get the deb, RPM-family images the rpm.
# For openEuler the image "openeuler/openeuler:24.03-lts" is tried first; if it
# cannot be pulled, rockylinux:9 stands in and the script says so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

step() { printf '\n==> %s\n' "$*"; }
die() { printf '  FAILED: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is required"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ $# -ge 1 ]; then
  BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  step "building the native CLI"
  TARGET_DIR="${TARGET_DIR:-$ROOT/_build}"
  moon build --target native --target-dir "$TARGET_DIR" cmd/main
  BIN="$(find "$TARGET_DIR/native/debug" -name main.exe -path '*cmd/main*' | head -n 1)"
fi
[ -x "$BIN" ] || die "linuxpkg binary not found"

COMPRESSIONS="gzip xz zstd none"

step "building the packages with every compression"
for c in $COMPRESSIONS; do
  "$BIN" build examples/hello/linuxpkg.json --compression "$c" --out "$WORK/pkgs/$c"
done
ls -lR "$WORK/pkgs"

run_deb() { # image
  local image="$1"
  step "$image: dpkg -i, run, dpkg -r for ${COMPRESSIONS}"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    for c in '"$COMPRESSIONS"'; do
      echo "-- $c"
      dpkg -i /pkgs/$c/hello_1.0.0-1_all.deb
      test "$(hello)" = "hello from linuxpkg"
      test "$(hi)" = "hello from linuxpkg"
      test "$(cat /var/lib/hello/state)" = installed
      test -f /etc/hello.conf
      dpkg --verify hello
      dpkg -r hello
      test ! -e /usr/bin/hello
      test ! -e /var/lib/hello/state
    done
    echo "container check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

run_rpm() { # image
  local image="$1"
  step "$image: rpm -i, run, rpm -V, rpm -e for ${COMPRESSIONS}"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    for c in '"$COMPRESSIONS"'; do
      echo "-- $c"
      rpm -K /pkgs/$c/hello-1.0.0-1.noarch.rpm
      rpm -ivh /pkgs/$c/hello-1.0.0-1.noarch.rpm
      test "$(hello)" = "hello from linuxpkg"
      test "$(hi)" = "hello from linuxpkg"
      test "$(cat /var/lib/hello/state)" = installed
      test -f /etc/hello.conf
      test "$(rpm -q hello)" = "hello-1.0.0-1.noarch"
      rpm -V hello
      rpm -e hello
      test ! -e /usr/bin/hello
      test ! -e /var/lib/hello/state
    done
    echo "container check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
  step "$image: dnf install of the xz and zstd files"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    for c in xz zstd; do
      dnf install -y /pkgs/$c/hello-1.0.0-1.noarch.rpm
      test "$(hello)" = "hello from linuxpkg"
      dnf remove -y hello
      test ! -e /usr/bin/hello
    done
  '
}

# Compare linuxpkg's reading of a genuine distribution package with the
# distribution's own tools, and verify it. $1 = label, $2 = expected
# compression, $3 = directory with report.json, expected.txt and files.txt.
compare_real() {
  local label="$1" expected="$2" dir="$3" package="$4"
  "$BIN" inspect "$package"
  "$BIN" inspect "$package" --json >"$dir/report.json"
  python3 - "$dir/report.json" "$dir/expected.txt" "$dir/files.txt" "$expected" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected = dict(line.split("=", 1) for line in open(sys.argv[2]).read().splitlines())
files = [l for l in open(sys.argv[3]).read().splitlines() if l]
def norm(path):
    path = path.lstrip(".")
    path = path.rstrip("/")
    return path or "/"
assert report["name"] == expected["name"], (report["name"], expected["name"])
assert report["version"] == expected["version"], (report["version"], expected["version"])
assert report["architecture"] == expected["arch"], (report["architecture"], expected["arch"])
comp = report["compression"]
got = comp.get("payload") or comp.get("data")
assert got == sys.argv[4], (comp, sys.argv[4])
ours = sorted(f["path"] for f in report["files"])
theirs = sorted(norm(p) for p in files)
assert ours == theirs, (ours, theirs)
assert len(report["files"]) == int(expected["files"]), (len(report["files"]), expected["files"])
print("  ok: name, version, arch, %s compression and %d file names agree with the distribution's tools" % (got, len(files)))
PY
  "$BIN" verify "$package" | tee "$dir/verify.out"
  grep -q "OK (" "$dir/verify.out" || die "$label: verify did not report OK"
  echo "  ok: $label verified in full (exit 0)"
}

real_deb() { # image expected-compression
  local image="$1" expected="$2"
  step "$image: linuxpkg reads and verifies the distribution's own hello deb"
  local dir="$WORK/real-$(echo "$image" | tr ':/' '__')"
  mkdir -p "$dir"
  docker run --rm -v "$dir:/out" "$image" bash -ec '
    apt-get update -qq >/dev/null
    cd /out && apt-get download hello >/dev/null
    f=$(ls /out/hello_*.deb | head -n 1)
    {
      echo "name=$(dpkg-deb -f "$f" Package)"
      echo "version=$(dpkg-deb -f "$f" Version)"
      echo "arch=$(dpkg-deb -f "$f" Architecture)"
      echo "files=$(dpkg-deb --contents "$f" | wc -l)"
    } > /out/expected.txt
    dpkg-deb --contents "$f" | sed "s/ -> .*//" | awk "{print \$6}" > /out/files.txt
  '
  compare_real "$image hello" "$expected" "$dir" "$(ls "$dir"/hello_*.deb | head -n 1)"
  docker run --rm -v "$dir:/out" "$image" sh -c 'rm -rf /out/*'
}

real_rpm() { # image package
  local image="$1" pkg="$2"
  step "$image: linuxpkg reads and verifies the distribution's own $pkg rpm"
  local dir="$WORK/real-$(echo "$image" | tr ':/' '__')"
  mkdir -p "$dir"
  docker run --rm -v "$dir:/out" "$image" bash -ec '
    dnf download --destdir /out '"$pkg"' || { dnf install -y dnf-plugins-core && dnf download --destdir /out '"$pkg"'; }
    f=$(ls /out/'"$pkg"'-*.rpm | head -n 1)
    {
      rpm -qp --qf "name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\ncompressor=%{PAYLOADCOMPRESSOR}\n" "$f"
      echo "files=$(rpm -qlp "$f" | wc -l)"
    } > /out/expected.txt
    rpm -qlp "$f" > /out/files.txt
    rpm -K "$f" || true
  '
  local real compressor
  real="$(ls "$dir"/"$pkg"-*.rpm | head -n 1)"
  compressor="$(grep '^compressor=' "$dir/expected.txt" | cut -d= -f2)"
  # The RPM comparison keys differ from the deb ones: map them.
  python3 - "$dir/expected.txt" <<'PY'
import sys
path = sys.argv[1]
lines = dict(l.split("=", 1) for l in open(path).read().splitlines())
lines["version"] = lines["version"] + "-" + lines.pop("release")
open(path, "w").write("".join("%s=%s\n" % kv for kv in lines.items()))
PY
  compare_real_rpm "$image $pkg" "$compressor" "$dir" "$real"
  docker run --rm -v "$dir:/out" "$image" sh -c 'rm -rf /out/*'
}

compare_real_rpm() {
  local label="$1" expected="$2" dir="$3" package="$4"
  "$BIN" inspect "$package"
  "$BIN" inspect "$package" --json >"$dir/report.json"
  python3 - "$dir/report.json" "$dir/expected.txt" "$dir/files.txt" "$expected" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected = dict(line.split("=", 1) for line in open(sys.argv[2]).read().splitlines())
files = [l for l in open(sys.argv[3]).read().splitlines() if l]
assert report["name"] == expected["name"], (report["name"], expected["name"])
assert report["version"] + "-" + report["release"] == expected["version"], (report["version"], report["release"], expected["version"])
assert report["architecture"] == expected["arch"], (report["architecture"], expected["arch"])
assert report["compression"]["payload"] == sys.argv[4], (report["compression"], sys.argv[4])
assert [f["path"] for f in report["files"]] == files
print("  ok: name, version, release, arch, %s payload and %d file names agree with rpm -qp" % (sys.argv[4], len(files)))
PY
  "$BIN" verify "$package" | tee "$dir/verify.out"
  grep -q "OK (" "$dir/verify.out" || die "$label: verify did not report OK"
  echo "  ok: $label verified in full (exit 0)"
}

run_deb debian:12
run_deb ubuntu:24.04
run_rpm fedora:41

real_deb debian:12 xz
real_deb ubuntu:24.04 zstd
real_rpm fedora:41 hello

OPENEULER="openeuler/openeuler:24.03-lts"
if docker pull "$OPENEULER" >/dev/null 2>&1; then
  run_rpm "$OPENEULER"
  real_rpm "$OPENEULER" tree
else
  echo "NOTE: $OPENEULER could not be pulled, using rockylinux:9 as the RPM-family substitute"
  run_rpm rockylinux:9
  real_rpm rockylinux:9 tree
fi

printf '\nAll container checks passed.\n'
