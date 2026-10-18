#!/usr/bin/env bash
# Install the example packages in real distribution containers and run them.
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
  BIN="$(find "$TARGET_DIR/native" -name main.exe -path '*cmd/main*' | head -n 1)"
fi
[ -x "$BIN" ] || die "linuxpkg binary not found"

step "building the packages"
"$BIN" build examples/hello/linuxpkg.json --out "$WORK/pkgs"
ls -l "$WORK/pkgs"

run_deb() { # image
  local image="$1"
  step "$image: dpkg -i, run, dpkg -r"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    dpkg -i /pkgs/hello_1.0.0-1_all.deb
    test "$(hello)" = "hello from linuxpkg"
    test "$(hi)" = "hello from linuxpkg"
    test "$(cat /var/lib/hello/state)" = installed
    test -f /etc/hello.conf
    dpkg --verify hello
    dpkg -r hello
    test ! -e /usr/bin/hello
    test ! -e /var/lib/hello/state
    echo "container check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

run_rpm() { # image
  local image="$1"
  step "$image: rpm -i, run, rpm -V, rpm -e"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    rpm -K /pkgs/hello-1.0.0-1.noarch.rpm
    rpm -ivh /pkgs/hello-1.0.0-1.noarch.rpm
    test "$(hello)" = "hello from linuxpkg"
    test "$(hi)" = "hello from linuxpkg"
    test "$(cat /var/lib/hello/state)" = installed
    test -f /etc/hello.conf
    test "$(rpm -q hello)" = "hello-1.0.0-1.noarch"
    rpm -V hello
    rpm -e hello
    test ! -e /usr/bin/hello
    test ! -e /var/lib/hello/state
    echo "container check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
  step "$image: dnf install of the same file"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" "$image" bash -ec '
    dnf install -y /pkgs/hello-1.0.0-1.noarch.rpm
    test "$(hello)" = "hello from linuxpkg"
    dnf remove -y hello
    test ! -e /usr/bin/hello
  '
}

real_distribution_rpm() { # image
  # Download a genuine distribution package (zstd payload, signed) with the
  # distribution's own dnf, and check that linuxpkg reads its header like rpm.
  local image="$1"
  step "$image: linuxpkg reads a real distribution rpm"
  mkdir -p "$WORK/real"
  docker run --rm -v "$WORK/real:/out" "$image" bash -ec '
    dnf download --destdir /out hello || { dnf install -y dnf-plugins-core && dnf download --destdir /out hello; }
    f=$(ls /out/hello-*.rpm | head -n 1)
    {
      rpm -qp --qf "name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\ncompressor=%{PAYLOADCOMPRESSOR}\n" "$f"
      echo "files=$(rpm -qlp "$f" | wc -l)"
    } > /out/expected.txt
    rpm -qlp "$f" > /out/files.txt
    rpm -K "$f" || true
  '
  local real
  real="$(ls "$WORK"/real/hello-*.rpm | head -n 1)"
  "$BIN" inspect "$real"
  "$BIN" inspect "$real" --json >"$WORK/real/report.json"
  python3 - "$WORK/real/report.json" "$WORK/real/expected.txt" "$WORK/real/files.txt" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected = dict(line.split("=", 1) for line in open(sys.argv[2]).read().splitlines())
files = open(sys.argv[3]).read().splitlines()
for key, field in (("name", "name"), ("version", "version"), ("release", "release"), ("arch", "architecture")):
    assert report[field] == expected[key], (field, report[field], expected[key])
assert report["compression"]["payload"] == expected["compressor"], (report["compression"], expected["compressor"])
assert len(report["files"]) == int(expected["files"]), (len(report["files"]), expected["files"])
assert [f["path"] for f in report["files"]] == files
print("  ok: name, version, release, arch, payload compressor and %d file names agree with rpm -qp" % len(files))
PY
  # The payload is compressed with zstd: verify must say so and not crash.
  set +e
  "$BIN" verify "$real" 2>"$WORK/real/verify.err"
  local status=$?
  set -e
  cat "$WORK/real/verify.err"
  if grep -q "zstd compression of the payload is not supported" "$WORK/real/verify.err"; then
    [ "$status" = 1 ] || die "unsupported compression must exit with 1, got $status"
    echo "  ok: verify reports the zstd payload as unsupported (exit 1)"
  else
    # An older release with a gzip payload: it has to verify cleanly.
    [ "$status" = 0 ] || die "verify of a real rpm failed with $status"
    echo "  ok: verify accepted the real rpm"
  fi
  docker run --rm -v "$WORK/real:/out" "$image" sh -c 'rm -rf /out/*'
}

run_deb debian:12
run_deb ubuntu:24.04
run_rpm fedora:41
real_distribution_rpm fedora:41

OPENEULER="openeuler/openeuler:24.03-lts"
if docker pull "$OPENEULER" >/dev/null 2>&1; then
  run_rpm "$OPENEULER"
else
  echo "NOTE: $OPENEULER could not be pulled, using rockylinux:9 as the RPM-family substitute"
  run_rpm rockylinux:9
fi

printf '\nAll container checks passed.\n'
