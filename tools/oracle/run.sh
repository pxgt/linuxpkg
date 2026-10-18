#!/usr/bin/env bash
# Oracle checks: packages built by linuxpkg must be accepted by the official
# tools (dpkg-deb, dpkg, ...). Exits non-zero on the first failed check.
#
# Usage: tools/oracle/run.sh [LINUXPKG_BINARY]
#
# Without an argument the native CLI is built with moon first. Set
# TARGET_DIR to build somewhere else than ./_build (useful in WSL, where the
# project lives on the Windows file system).
#
# Needs: dpkg-deb, dpkg and sudo (or root). lintian is optional: its output
# is recorded but never fails the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

WORK="$(mktemp -d)"
# Files created by "sudo rpm --root" belong to root, so clean up with sudo too.
trap '$SUDO rm -rf "$WORK" 2>/dev/null || true' EXIT

step() { printf '\n==> %s\n' "$*"; }
pass() { printf '  ok: %s\n' "$*"; }
die() { printf '  FAILED: %s\n' "$*" >&2; exit 1; }

expect_eq() { # description actual expected
  if [ "$2" != "$3" ]; then
    die "$1: expected '$3', got '$2'"
  fi
  pass "$1"
}

expect_in() { # description needle haystack
  if ! grep -qF -- "$2" <<<"$3"; then
    die "$1: '$2' not found in:
$3"
  fi
  pass "$1"
}

# ---------------------------------------------------------------- binary
if [ $# -ge 1 ]; then
  BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
  step "building the native CLI"
  TARGET_DIR="${TARGET_DIR:-$ROOT/_build}"
  moon build --target native --target-dir "$TARGET_DIR" cmd/main
  BIN="$(find "$TARGET_DIR/native" -name main.exe -path '*cmd/main*' | head -n 1)"
fi
[ -x "$BIN" ] || die "linuxpkg binary not found"
pass "using $BIN"
"$BIN" --version

EXAMPLE="$ROOT/examples/hello/linuxpkg.json"

# ---------------------------------------------------------------- deb
step "building examples/hello as a deb"
"$BIN" build "$EXAMPLE" --format deb --out "$WORK/deb"
DEB="$WORK/deb/hello_1.0.0-1_all.deb"
[ -f "$DEB" ] || die "expected $DEB"
pass "built $(basename "$DEB") ($(stat -c %s "$DEB") bytes)"

step "dpkg-deb reads the package"
dpkg-deb --info "$DEB" >"$WORK/info.txt"
FIELDS="$(dpkg-deb --field "$DEB" Package Version Architecture Maintainer Section Priority Homepage)"
expect_in "Package" "Package: hello" "$FIELDS"
expect_in "Version" "Version: 1.0.0-1" "$FIELDS"
expect_in "Architecture" "Architecture: all" "$FIELDS"
expect_in "Maintainer" "Maintainer: pxgt <133531533+pxgt@users.noreply.github.com>" "$FIELDS"
expect_in "Homepage" "Homepage: https://github.com/pxgt/linuxpkg" "$FIELDS"
CONTENTS="$(dpkg-deb --contents "$DEB")"
for path in ./ ./usr/bin/hello ./usr/bin/hi ./etc/hello.conf ./var/lib/hello/ \
  ./usr/share/doc/hello/README.txt; do
  expect_in "contents list $path" " $path" "$CONTENTS"
done
expect_in "symlink target" "./usr/bin/hi -> hello" "$CONTENTS"
expect_in "executable mode" "-rwxr-xr-x root/root" "$CONTENTS"
EXTRACT="$WORK/extract"
mkdir "$EXTRACT"
dpkg-deb --extract "$DEB" "$EXTRACT"
expect_eq "extracted program" "$("$EXTRACT/usr/bin/hello")" "hello from linuxpkg"
cmp "$EXTRACT/usr/bin/hello" examples/hello/hello.sh
cmp "$EXTRACT/etc/hello.conf" examples/hello/hello.conf
pass "extracted files are identical to the sources"
CONTROL="$WORK/control"
mkdir "$CONTROL"
dpkg-deb --control "$DEB" "$CONTROL"
expect_eq "conffiles" "$(cat "$CONTROL/conffiles")" "/etc/hello.conf"
[ -x "$CONTROL/postinst" ] || die "postinst must be executable"
(cd "$EXTRACT" && md5sum -c --quiet "$CONTROL/md5sums") || die "md5sums do not match"
pass "md5sums match the extracted files"

step "dpkg installs, verifies and removes the package"
$SUDO dpkg -i "$DEB"
expect_eq "installed program" "$(/usr/bin/hello)" "hello from linuxpkg"
expect_eq "symlink works" "$(/usr/bin/hi)" "hello from linuxpkg"
expect_eq "symlink target" "$(readlink /usr/bin/hi)" "hello"
[ -f /etc/hello.conf ] || die "config file missing"
expect_eq "postinst ran" "$(cat /var/lib/hello/state)" "installed"
dpkg --verify hello && pass "dpkg --verify finds no differences"
expect_in "dpkg -L lists the program" "/usr/bin/hello" "$(dpkg -L hello)"
expect_in "dpkg -s version" "Version: 1.0.0-1" "$(dpkg -s hello)"
expect_in "dpkg -s conffile" "/etc/hello.conf" "$(dpkg -s hello)"
$SUDO dpkg -r hello
[ ! -e /usr/bin/hello ] || die "program still installed after removal"
[ ! -e /var/lib/hello/state ] || die "postrm did not remove the marker"
[ -f /etc/hello.conf ] || die "conffile must survive 'dpkg -r'"
pass "removed, conffile kept"
$SUDO dpkg -P hello
[ ! -e /etc/hello.conf ] || die "conffile must be gone after purge"
pass "purged"

step "lintian (recorded, never fatal)"
if command -v lintian >/dev/null 2>&1; then
  lintian "$DEB" >"$WORK/lintian.txt" 2>&1 || true
  cat "$WORK/lintian.txt"
  pass "lintian reported $(grep -c '^E:' "$WORK/lintian.txt" || true) error(s), $(grep -c '^W:' "$WORK/lintian.txt" || true) warning(s)"
else
  echo "  lintian not installed, skipped"
fi

# ---------------------------------------------------------------- rpm
if command -v rpm >/dev/null 2>&1 && command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
  HAVE_RPM=1
else
  HAVE_RPM=0
  echo "rpm, rpm2cpio or cpio is missing: skipping the rpm checks"
fi

if [ "$HAVE_RPM" = 1 ]; then
  step "building examples/hello as an rpm"
  "$BIN" build "$EXAMPLE" --format rpm --out "$WORK/rpm"
  RPM="$WORK/rpm/hello-1.0.0-1.noarch.rpm"
  [ -f "$RPM" ] || die "expected $RPM"
  pass "built $(basename "$RPM") ($(stat -c %s "$RPM") bytes)"

  step "rpm accepts the package"
  rpm --version
  KOUT="$(rpm -K --nosignature "$RPM" 2>&1)"
  expect_in "rpm -K --nosignature" "digests OK" "$KOUT"
  KVOUT="$(rpm -Kv "$RPM" 2>&1 || true)"
  expect_in "header SHA256 digest" "Header SHA256 digest: OK" "$KVOUT"
  expect_in "payload SHA256 digest" "Payload SHA256 digest: OK" "$KVOUT"
  expect_eq "rpm -qp --qf" "$(rpm -qp --qf '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "$RPM")" "hello 1.0.0 1 noarch"
  QI="$(rpm -qip "$RPM")"
  expect_in "rpm -qip license" "License     : Apache-2.0" "$QI"
  expect_in "rpm -qip url" "URL         : https://github.com/pxgt/linuxpkg" "$QI"
  expect_in "rpm -qip summary" "Summary     : Example program packaged with linuxpkg" "$QI"
  QL="$(rpm -qlp "$RPM")"
  expect_eq "rpm -qlp file list" "$QL" "/etc/hello.conf
/usr/bin/hello
/usr/bin/hi
/usr/share/doc/hello/README.txt
/var/lib/hello"
  expect_eq "rpm -qcp config files" "$(rpm -qcp "$RPM")" "/etc/hello.conf"
  QLV="$(rpm -qlvp "$RPM")"
  expect_in "executable mode" "-rwxr-xr-x" "$QLV"
  expect_in "symlink" "/usr/bin/hi -> hello" "$QLV"
  expect_in "directory" "drwxr-xr-x" "$QLV"
  QS="$(rpm -qp --scripts "$RPM")"
  expect_in "postinstall script" "echo installed > /var/lib/hello/state" "$QS"
  expect_in "postuninstall script" "rm -f /var/lib/hello/state" "$QS"
  expect_in "provides itself" "hello = 1.0.0-1" "$(rpm -qp --provides "$RPM")"
  expect_in "requires rpmlib features" "rpmlib(FileDigests)" "$(rpm -qp --requires "$RPM")"

  step "rpm2cpio | cpio extracts identical files"
  mkdir "$WORK/rpm-extract"
  (cd "$WORK/rpm-extract" && rpm2cpio "$RPM" | cpio -idm --quiet)
  cmp "$WORK/rpm-extract/usr/bin/hello" examples/hello/hello.sh
  cmp "$WORK/rpm-extract/etc/hello.conf" examples/hello/hello.conf
  cmp "$WORK/rpm-extract/usr/share/doc/hello/README.txt" examples/hello/README.txt
  expect_eq "symlink target" "$(readlink "$WORK/rpm-extract/usr/bin/hi")" "hello"
  [ -d "$WORK/rpm-extract/var/lib/hello" ] || die "directory missing"
  pass "payload files are identical to the sources"

  step "rpm installs, verifies and erases the package in a private root"
  ROOT="$WORK/rpm-root"
  mkdir -p "$ROOT"
  $SUDO rpm --root "$ROOT" --initdb
  # Scriptlets need a shell inside the root, so they are skipped here; the
  # container job runs them for real.
  $SUDO rpm --root "$ROOT" -ivh --noscripts --nodeps "$RPM" >"$WORK/rpm-install.txt" 2>&1 || {
    cat "$WORK/rpm-install.txt"
    die "rpm -i failed"
  }
  expect_eq "rpm -q" "$($SUDO rpm --root "$ROOT" -q hello)" "hello-1.0.0-1.noarch"
  [ -x "$ROOT/usr/bin/hello" ] || die "program not installed"
  expect_eq "installed program" "$("$ROOT/usr/bin/hello")" "hello from linuxpkg"
  expect_eq "installed symlink" "$(readlink "$ROOT/usr/bin/hi")" "hello"
  # -V compares size, digest, mode, owner, link target and mtime of every file.
  VERIFY_OUT="$($SUDO rpm --root "$ROOT" -V hello 2>&1 || true)"
  if [ -n "$VERIFY_OUT" ]; then
    echo "$VERIFY_OUT"
    die "rpm -V found differences"
  fi
  pass "rpm -V finds no differences"
  expect_eq "config file flag" "$($SUDO rpm --root "$ROOT" -qc hello)" "/etc/hello.conf"
  $SUDO rpm --root "$ROOT" -e --noscripts hello
  [ ! -e "$ROOT/usr/bin/hello" ] || die "program still installed after erase"
  pass "erased"
fi

# ---------------------------------------------------------------- reverse
step "inspect and verify our own deb"
"$BIN" verify "$DEB"
"$BIN" inspect "$DEB" --json >"$WORK/ours.json"
"$BIN" inspect "$DEB" >"$WORK/ours.txt"
expect_in "text report names the package" "Package:       hello" "$(cat "$WORK/ours.txt")"

step "linuxpkg reads a deb written by the real dpkg-deb"
mkdir "$WORK/ref"
dpkg-deb --raw-extract "$DEB" "$WORK/ref/tree"
SOURCE_DATE_EPOCH=1700000000 dpkg-deb --root-owner-group -Zgzip --build "$WORK/ref/tree" "$WORK/ref/dpkg.deb" >/dev/null
"$BIN" verify "$WORK/ref/dpkg.deb"
"$BIN" inspect "$WORK/ref/dpkg.deb" --json >"$WORK/ref/dpkg.json"
python3 - "$WORK/ref/dpkg.json" "$WORK/ref/dpkg.deb" <<'PY'
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
deb = sys.argv[2]
def field(name):
    return subprocess.check_output(["dpkg-deb", "--field", deb, name], text=True).strip()
for key, name in (("name", "Package"), ("version", "Version"), ("architecture", "Architecture")):
    assert report[key] == field(name), (key, report[key], field(name))
# The member list of dpkg-deb --contents: "perms owner/group size date time path [-> target]"
listed = {}
for line in subprocess.check_output(["dpkg-deb", "--contents", deb], text=True).splitlines():
    parts = line.split(None, 5)
    path = parts[5].split(" -> ")[0]
    listed[path.lstrip(".") or "/"] = (parts[0], parts[1], int(parts[2]))
ours = {f["path"]: f for f in report["files"]}
assert len(ours) == len(listed), (sorted(ours), sorted(listed))
for path, (perms, owner, size) in listed.items():
    key = path.rstrip("/") or "/"
    f = ours[key]
    assert f["owner"] + "/" + f["group"] == owner, (path, f, owner)
    assert f["size"] == size, (path, f["size"], size)
    assert perms[0] == {"dir": "d", "file": "-", "symlink": "l"}[f["type"]], (path, perms, f)
assert report["conffiles"] == ["/etc/hello.conf"], report["conffiles"]
assert report["scripts"] == ["postinst", "postrm"], report["scripts"]
assert report["compression"] == {"control": "gzip", "data": "gzip"}
print("  ok: inspect --json agrees with dpkg-deb on %d entries" % len(listed))
PY

step "verify rejects damaged and tampered packages"
python3 - "$WORK/ref/dpkg.deb" "$WORK/ref/flipped.deb" <<'PY'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
data[len(data) - 20] ^= 0xFF  # inside data.tar.gz
open(sys.argv[2], "wb").write(data)
PY
set +e
"$BIN" verify "$WORK/ref/flipped.deb" 2>"$WORK/err.txt"
STATUS=$?
set -e
expect_eq "damaged gzip exits with 2" "$STATUS" "2"
# Change a file but keep the md5sums: dpkg-deb happily builds it, verify must not.
cp -r "$WORK/ref/tree" "$WORK/ref/forged"
echo "echo pwned" >>"$WORK/ref/forged/usr/bin/hello"
SOURCE_DATE_EPOCH=1700000000 dpkg-deb --root-owner-group -Zgzip --build "$WORK/ref/forged" "$WORK/ref/forged.deb" >/dev/null
set +e
"$BIN" verify "$WORK/ref/forged.deb" 2>"$WORK/err.txt"
STATUS=$?
set -e
expect_eq "md5 mismatch exits with 2" "$STATUS" "2"
expect_in "mismatch names the file" "/usr/bin/hello: md5 mismatch" "$(cat "$WORK/err.txt")"
# An xz compressed deb is valid but unsupported: exit 1, not 2, and no crash.
dpkg-deb --root-owner-group -Zxz --build "$WORK/ref/tree" "$WORK/ref/xz.deb" >/dev/null
set +e
"$BIN" verify "$WORK/ref/xz.deb" 2>"$WORK/err.txt"
STATUS=$?
set -e
expect_eq "xz exits with 1" "$STATUS" "1"
expect_in "xz is reported as unsupported" "xz compression is not supported" "$(cat "$WORK/err.txt")"
printf 'not a package' >"$WORK/junk.deb"
set +e
"$BIN" verify "$WORK/junk.deb" 2>"$WORK/err.txt"
STATUS=$?
set -e
expect_eq "a non-package exits with 1" "$STATUS" "1"

# ---------------------------------------------------------------- reproducible
step "reproducible builds"
"$BIN" build "$EXAMPLE" --out "$WORK/again1"
"$BIN" build "$EXAMPLE" --out "$WORK/again2"
cmp "$DEB" "$WORK/again1/hello_1.0.0-1_all.deb"
cmp "$WORK/again1/hello_1.0.0-1_all.deb" "$WORK/again2/hello_1.0.0-1_all.deb"
cmp "$WORK/again1/hello-1.0.0-1.noarch.rpm" "$WORK/again2/hello-1.0.0-1.noarch.rpm"
pass "builds of the same config are byte-identical (deb and rpm)"
# Same config without an mtime: SOURCE_DATE_EPOCH decides.
sed '/"mtime"/d' "$EXAMPLE" >"$WORK/nomtime.json"
for f in hello.sh hello.conf README.txt; do cp "examples/hello/$f" "$WORK/$f"; done
cp -r examples/hello/scripts "$WORK/scripts"
SOURCE_DATE_EPOCH=1000000000 "$BIN" build "$WORK/nomtime.json" --out "$WORK/e1"
SOURCE_DATE_EPOCH=1000000000 "$BIN" build "$WORK/nomtime.json" --out "$WORK/e2"
SOURCE_DATE_EPOCH=1000000001 "$BIN" build "$WORK/nomtime.json" --out "$WORK/e3"
cmp "$WORK/e1/hello_1.0.0-1_all.deb" "$WORK/e2/hello_1.0.0-1_all.deb"
if cmp -s "$WORK/e1/hello_1.0.0-1_all.deb" "$WORK/e3/hello_1.0.0-1_all.deb"; then
  die "SOURCE_DATE_EPOCH must change the output"
fi
pass "SOURCE_DATE_EPOCH controls the timestamps"
expect_in "timestamps follow SOURCE_DATE_EPOCH" "2001-09-09" "$(dpkg-deb --contents "$WORK/e1/hello_1.0.0-1_all.deb")"

printf '\nAll oracle checks passed.\n'
