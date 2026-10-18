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

if [ "$HAVE_RPM" = 1 ] && command -v rpmbuild >/dev/null 2>&1; then
  step "inspect and verify our own rpm"
  "$BIN" verify "$RPM"
  "$BIN" inspect "$RPM" >"$WORK/ours-rpm.txt"
  expect_in "text report names the package" "Package:       hello" "$(cat "$WORK/ours-rpm.txt")"

  step "linuxpkg reads an rpm written by the real rpmbuild"
  RB="$WORK/rpmbuild"
  mkdir -p "$RB/top/SPECS"
  cat >"$RB/top/SPECS/hello.spec" <<'SPEC'
Name: hello
Version: 1.0.0
Release: 1
Summary: Reference package built by rpmbuild
License: Apache-2.0
BuildArch: noarch
AutoReqProv: no
Requires: bash >= 4.0

%description
Reference package built by the real rpmbuild from the files linuxpkg packaged.

%install
mkdir -p %{buildroot}
cp -a %{extracted}/. %{buildroot}/

%files
%defattr(-,root,root,-)
%config /etc/hello.conf
/usr/bin/hello
/usr/bin/hi
%dir /var/lib/hello
/usr/share/doc/hello/README.txt
SPEC
  SOURCE_DATE_EPOCH=1700000000 rpmbuild -bb --define "_topdir $RB/top" \
    --define "_binary_payload w9.gzdio" --define "extracted $WORK/rpm-extract" \
    --define "_build_id_links none" --define "clamp_mtime_to_source_date_epoch 1" \
    "$RB/top/SPECS/hello.spec" >"$RB/build.log" 2>&1 || { cat "$RB/build.log"; die "rpmbuild failed"; }
  REF="$RB/top/RPMS/noarch/hello-1.0.0-1.noarch.rpm"
  [ -f "$REF" ] || die "rpmbuild produced no package"
  rpm -K "$REF" >/dev/null
  "$BIN" verify "$REF"
  "$BIN" inspect "$REF" --json >"$RB/ref.json"
  python3 - "$RB/ref.json" "$REF" <<'PY'
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
rpm = sys.argv[2]
def q(fmt):
    return subprocess.check_output(["rpm", "-qp", "--qf", fmt, rpm], text=True)
assert report["format"] == "rpm"
for key, tag in (("name", "NAME"), ("version", "VERSION"), ("release", "RELEASE"), ("architecture", "ARCH")):
    assert report[key] == q("%{" + tag + "}"), (key, report[key], q("%{" + tag + "}"))
paths = q("[%{FILENAMES}\n]").splitlines()
assert [f["path"] for f in report["files"]] == paths, (paths, report["files"])
sizes = [int(x) for x in q("[%{FILESIZES}\n]").splitlines()]
assert [f["size"] for f in report["files"]] == sizes
users = q("[%{FILEUSERNAME}/%{FILEGROUPNAME}\n]").splitlines()
assert [f["owner"] + "/" + f["group"] for f in report["files"]] == users
modes = [int(x) for x in q("[%{FILEMODES}\n]").splitlines()]
for f, m in zip(report["files"], modes):
    assert f["mode"] == "0%o" % (m & 0o7777), (f, m)
flags = [int(x) for x in q("[%{FILEFLAGS}\n]").splitlines()]
assert report["conffiles"] == [p for p, fl in zip(paths, flags) if fl & 1], report["conffiles"]
assert report["depends"] == ["bash >= 4.0"], report["depends"]
assert report["compression"] == {"payload": "gzip"}
print("  ok: inspect --json agrees with rpm -qp on %d files" % len(paths))
PY

  step "verify rejects damaged and tampered rpms"
  python3 - "$REF" "$RB/flipped.rpm" <<'PY'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
data[len(data) - 40] ^= 0xFF  # inside the payload
open(sys.argv[2], "wb").write(data)
PY
  set +e
  "$BIN" verify "$RB/flipped.rpm" 2>"$WORK/err.txt"
  STATUS=$?
  set -e
  expect_eq "damaged payload exits with 2" "$STATUS" "2"
  expect_in "reported as a digest mismatch" "mismatch" "$(cat "$WORK/err.txt")"
  # A payload compressed with xz is valid but unsupported: exit 1, no crash.
  SOURCE_DATE_EPOCH=1700000000 rpmbuild -bb --define "_topdir $RB/top" \
    --define "_binary_payload w2.xzdio" --define "extracted $WORK/rpm-extract" \
    --define "_build_id_links none" --define "clamp_mtime_to_source_date_epoch 1" \
    "$RB/top/SPECS/hello.spec" >"$RB/build-xz.log" 2>&1 || die "rpmbuild (xz) failed"
  XZ_RPM="$RB/top/RPMS/noarch/hello-1.0.0-1.noarch.rpm"
  set +e
  "$BIN" verify "$XZ_RPM" 2>"$WORK/err.txt"
  STATUS=$?
  set -e
  expect_eq "xz payload exits with 1" "$STATUS" "1"
  expect_in "xz is reported as unsupported" "xz compression of the payload is not supported" "$(cat "$WORK/err.txt")"
  "$BIN" inspect "$XZ_RPM" >/dev/null
  pass "inspect still works on the xz rpm"
fi

# ---------------------------------------------------------------- relations
step "dependency relations reach both formats"
DEPS="$WORK/deps"
mkdir -p "$DEPS"
printf '#!/bin/sh\necho deps\n' >"$DEPS/tool.sh"
cat >"$DEPS/linuxpkg.json" <<'JSON'
{
  "name": "relations",
  "version": "2.1.0",
  "release": "3",
  "epoch": 1,
  "arch": "amd64",
  "maintainer": "Test <test@example.org>",
  "description": "Relations test\nChecks how depends, conflicts, replaces and provides are written.",
  "mtime": 1700000000,
  "depends": ["libc6 (>= 2.31)", "bash", "zlib1g (<< 2.0)", "coreutils = 8.32"],
  "recommends": ["less"],
  "suggests": ["man-db > 2"],
  "conflicts": ["relations-old (<< 1.0)"],
  "replaces": ["relations-old"],
  "provides": ["relations-compat (= 2.1)"],
  "contents": [{ "src": "tool.sh", "dst": "/usr/bin/relations-tool", "mode": "0755" }]
}
JSON
"$BIN" build "$DEPS/linuxpkg.json" --out "$DEPS/out"
RDEB="$DEPS/out/relations_2.1.0-3_amd64.deb"
expect_eq "deb file name" "$(ls "$DEPS/out" | grep deb)" "relations_2.1.0-3_amd64.deb"
expect_eq "deb Version (with epoch)" "$(dpkg-deb --field "$RDEB" Version)" "1:2.1.0-3"
expect_eq "deb Depends" "$(dpkg-deb --field "$RDEB" Depends)" "libc6 (>= 2.31), bash, zlib1g (<< 2.0), coreutils (= 8.32)"
expect_eq "deb Recommends" "$(dpkg-deb --field "$RDEB" Recommends)" "less"
expect_eq "deb Suggests" "$(dpkg-deb --field "$RDEB" Suggests)" "man-db (>> 2)"
expect_eq "deb Conflicts" "$(dpkg-deb --field "$RDEB" Conflicts)" "relations-old (<< 1.0)"
expect_eq "deb Replaces" "$(dpkg-deb --field "$RDEB" Replaces)" "relations-old"
expect_eq "deb Provides" "$(dpkg-deb --field "$RDEB" Provides)" "relations-compat (= 2.1)"
if [ "$HAVE_RPM" = 1 ]; then
  RRPM="$DEPS/out/relations-2.1.0-3.x86_64.rpm"
  [ -f "$RRPM" ] || die "expected $RRPM"
  expect_eq "rpm epoch" "$(rpm -qp --qf '%{EPOCH}' "$RRPM")" "1"
  expect_eq "rpm Requires" "$(rpm -qp --requires "$RRPM" | grep -v '^rpmlib(')" "bash
coreutils = 8.32
libc6 >= 2.31
zlib1g < 2.0"
  expect_eq "rpm Conflicts" "$(rpm -qp --conflicts "$RRPM")" "relations-old < 1.0"
  expect_eq "rpm Obsoletes" "$(rpm -qp --obsoletes "$RRPM")" "relations-old"
  expect_eq "rpm Provides" "$(rpm -qp --provides "$RRPM")" "relations = 1:2.1.0-3
relations-compat = 2.1"
  expect_eq "rpm Recommends" "$(rpm -qp --recommends "$RRPM")" "less"
  expect_eq "rpm Suggests" "$(rpm -qp --suggests "$RRPM")" "man-db > 2"
  # The reader maps them back.
  "$BIN" inspect "$RRPM" --json >"$DEPS/rpm.json"
  python3 - "$DEPS/rpm.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["depends"] == ["bash", "coreutils = 8.32", "libc6 >= 2.31", "zlib1g < 2.0"], r["depends"]
assert r["conflicts"] == ["relations-old < 1.0"], r["conflicts"]
assert r["replaces"] == ["relations-old"], r["replaces"]
assert r["recommends"] == ["less"] and r["suggests"] == ["man-db > 2"]
assert r["provides"] == ["relations = 1:2.1.0-3", "relations-compat = 2.1"], r["provides"]
assert r["epoch"] == 1
print("  ok: inspect --json reads the relations back")
PY
fi

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
