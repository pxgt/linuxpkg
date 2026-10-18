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

run_deb debian:12
run_deb ubuntu:24.04
run_rpm fedora:41

OPENEULER="openeuler/openeuler:24.03-lts"
if docker pull "$OPENEULER" >/dev/null 2>&1; then
  run_rpm "$OPENEULER"
else
  echo "NOTE: $OPENEULER could not be pulled, using rockylinux:9 as the RPM-family substitute"
  run_rpm rockylinux:9
fi

printf '\nAll container checks passed.\n'
