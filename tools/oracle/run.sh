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
  BIN="$(find "$TARGET_DIR/native/debug" -name main.exe -path '*cmd/main*' | head -n 1)"
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
  RPMROOT="$WORK/rpm-root"
  mkdir -p "$RPMROOT"
  $SUDO rpm --root "$RPMROOT" --initdb
  # Scriptlets need a shell inside the root, so they are skipped here; the
  # container job runs them for real.
  $SUDO rpm --root "$RPMROOT" -ivh --noscripts --nodeps "$RPM" >"$WORK/rpm-install.txt" 2>&1 || {
    cat "$WORK/rpm-install.txt"
    die "rpm -i failed"
  }
  expect_eq "rpm -q" "$($SUDO rpm --root "$RPMROOT" -q hello)" "hello-1.0.0-1.noarch"
  [ -x "$RPMROOT/usr/bin/hello" ] || die "program not installed"
  expect_eq "installed program" "$("$RPMROOT/usr/bin/hello")" "hello from linuxpkg"
  expect_eq "installed symlink" "$(readlink "$RPMROOT/usr/bin/hi")" "hello"
  # -V compares size, digest, mode, owner, link target and mtime of every file.
  VERIFY_OUT="$($SUDO rpm --root "$RPMROOT" -V hello 2>&1 || true)"
  if [ -n "$VERIFY_OUT" ]; then
    echo "$VERIFY_OUT"
    die "rpm -V found differences"
  fi
  pass "rpm -V finds no differences"
  expect_eq "config file flag" "$($SUDO rpm --root "$RPMROOT" -qc hello)" "/etc/hello.conf"
  $SUDO rpm --root "$RPMROOT" -e --noscripts hello
  [ ! -e "$RPMROOT/usr/bin/hello" ] || die "program still installed after erase"
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
# Debs written by dpkg-deb with xz, zstd and no compression are verified in full.
for COMP in xz zstd none; do
  dpkg-deb --root-owner-group -Z$COMP --build "$WORK/ref/tree" "$WORK/ref/$COMP.deb" >/dev/null
  VERIFIED="$("$BIN" verify "$WORK/ref/$COMP.deb")"
  expect_in "dpkg-deb -Z$COMP deb verifies" "OK" "$VERIFIED"
  "$BIN" inspect "$WORK/ref/$COMP.deb" --json >"$WORK/ref/$COMP.json"
  python3 - "$WORK/ref/$COMP.json" "$COMP" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
want = {"control": sys.argv[2], "data": sys.argv[2]}
assert report["compression"] == want, report["compression"]
assert report["name"] == "hello" and len(report["files"]) == 14, report["files"]
print("  ok: inspect --json reads the %s members" % sys.argv[2])
PY
done
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
  # Payloads that rpmbuild compressed with xz and zstd are verified in full.
  for PAYLOAD in "w2.xzdio:xz" "w19.zstdio:zstd" "w.ufdio:identity"; do
    FLAGS="${PAYLOAD%%:*}"
    NAME="${PAYLOAD##*:}"
    SOURCE_DATE_EPOCH=1700000000 rpmbuild -bb --define "_topdir $RB/top" \
      --define "_binary_payload $FLAGS" --define "extracted $WORK/rpm-extract" \
      --define "_build_id_links none" --define "clamp_mtime_to_source_date_epoch 1" \
      "$RB/top/SPECS/hello.spec" >"$RB/build-$NAME.log" 2>&1 || {
        echo "  rpmbuild cannot write $NAME payloads here, skipped"
        continue
      }
    REF_RPM="$RB/top/RPMS/noarch/hello-1.0.0-1.noarch.rpm"
    VERIFIED="$("$BIN" verify "$REF_RPM")"
    expect_in "rpmbuild $NAME payload verifies" "OK" "$VERIFIED"
    "$BIN" inspect "$REF_RPM" --json >"$RB/ref-$NAME.json"
    python3 - "$RB/ref-$NAME.json" "$NAME" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
assert report["compression"] == {"payload": sys.argv[2]}, report["compression"]
assert len(report["files"]) == 5, report["files"]
print("  ok: inspect --json reads the %s payload" % sys.argv[2])
PY
  done
fi

# ---------------------------------------------------------------- compression
for COMP in xz zstd none; do
  step "packages built with --compression $COMP are accepted by the official tools"
  OUTC="$WORK/comp-$COMP"
  "$BIN" build "$EXAMPLE" --compression "$COMP" --out "$OUTC"
  CDEB="$OUTC/hello_1.0.0-1_all.deb"
  case "$COMP" in xz) EXT=.xz ;; zstd) EXT=.zst ;; none) EXT= ;; esac
  expect_eq "$COMP: ar members" "$(ar t "$CDEB" | tr '\n' ' ')" "debian-binary control.tar$EXT data.tar$EXT "
  dpkg-deb --info "$CDEB" >/dev/null
  expect_eq "$COMP: dpkg-deb --field" "$(dpkg-deb --field "$CDEB" Package)" "hello"
  CONTENTS="$(dpkg-deb --contents "$CDEB")"
  expect_in "$COMP: contents" "./usr/bin/hello" "$CONTENTS"
  expect_in "$COMP: symlink" "./usr/bin/hi -> hello" "$CONTENTS"
  mkdir "$OUTC/extract"
  dpkg-deb --extract "$CDEB" "$OUTC/extract"
  cmp "$OUTC/extract/usr/bin/hello" examples/hello/hello.sh
  cmp "$OUTC/extract/etc/hello.conf" examples/hello/hello.conf
  mkdir "$OUTC/control"
  dpkg-deb --control "$CDEB" "$OUTC/control"
  (cd "$OUTC/extract" && md5sum -c --quiet "$OUTC/control/md5sums") || die "$COMP: md5sums do not match"
  pass "$COMP: dpkg-deb extracts files identical to the sources"
  $SUDO dpkg -i "$CDEB" >/dev/null
  expect_eq "$COMP: installed program" "$(/usr/bin/hello)" "hello from linuxpkg"
  dpkg --verify hello && pass "$COMP: dpkg --verify finds no differences"
  $SUDO dpkg -P hello >/dev/null
  [ ! -e /usr/bin/hello ] || die "$COMP: program still installed after purge"
  "$BIN" verify "$CDEB" >/dev/null
  pass "$COMP: our verify accepts the deb"
  if [ "$HAVE_RPM" = 1 ]; then
    CRPM="$OUTC/hello-1.0.0-1.noarch.rpm"
    KOUT="$(rpm -K --nosignature "$CRPM" 2>&1)"
    expect_in "$COMP: rpm -K" "digests OK" "$KOUT"
    KVOUT="$(rpm -Kv "$CRPM" 2>&1 || true)"
    expect_in "$COMP: payload SHA256 digest" "Payload SHA256 digest: OK" "$KVOUT"
    REQ="$(rpm -qp --requires "$CRPM")"
    case "$COMP" in
      xz) expect_in "$COMP: rpmlib requirement" "rpmlib(PayloadIsXz) <= 5.2-1" "$REQ" ;;
      zstd) expect_in "$COMP: rpmlib requirement" "rpmlib(PayloadIsZstd) <= 5.4.18-1" "$REQ" ;;
      none) if grep -q "PayloadIs" <<<"$REQ"; then die "none: no PayloadIs requirement expected"; fi ;;
    esac
    expect_eq "$COMP: payload compressor" "$(rpm -qp --qf '%{PAYLOADCOMPRESSOR}' "$CRPM")" "$([ "$COMP" = none ] && echo "(none)" || echo "$COMP")"
    mkdir "$OUTC/rpm-extract"
    (cd "$OUTC/rpm-extract" && rpm2cpio "$CRPM" | cpio -idm --quiet)
    cmp "$OUTC/rpm-extract/usr/bin/hello" examples/hello/hello.sh
    cmp "$OUTC/rpm-extract/etc/hello.conf" examples/hello/hello.conf
    pass "$COMP: rpm2cpio extracts files identical to the sources"
    CROOT="$OUTC/rpm-root"
    mkdir -p "$CROOT"
    $SUDO rpm --root "$CROOT" --initdb
    $SUDO rpm --root "$CROOT" -ivh --noscripts --nodeps "$CRPM" >"$OUTC/rpm-install.txt" 2>&1 || {
      cat "$OUTC/rpm-install.txt"
      die "$COMP: rpm -i failed"
    }
    VERIFY_OUT="$($SUDO rpm --root "$CROOT" -V hello 2>&1 || true)"
    if [ -n "$VERIFY_OUT" ]; then echo "$VERIFY_OUT"; die "$COMP: rpm -V found differences"; fi
    pass "$COMP: rpm installs the package and rpm -V finds no differences"
    "$BIN" verify "$CRPM" >/dev/null
    pass "$COMP: our verify accepts the rpm"
  fi
done
# Per-format settings in the configuration.
sed 's/"mtime": 1700000000,/"mtime": 1700000000, "compression": "xz", "rpm": {"compression": "zstd"},/' "$EXAMPLE" >"$WORK/mixed.json"
if ! grep -q '"rpm": {"compression"' "$WORK/mixed.json"; then
  # The example has no mtime line to hook into: add the keys after the opening brace.
  sed '0,/{/s//{ "compression": "xz", "rpm": {"compression": "zstd"},/' "$EXAMPLE" >"$WORK/mixed.json"
fi
for f in hello.sh hello.conf README.txt; do cp "examples/hello/$f" "$WORK/$f"; done
cp -r examples/hello/scripts "$WORK/scripts" 2>/dev/null || true
"$BIN" build "$WORK/mixed.json" --out "$WORK/mixed"
expect_eq "config: deb uses the package-wide xz" "$(ar t "$WORK/mixed/hello_1.0.0-1_all.deb" | tr '\n' ' ')" "debian-binary control.tar.xz data.tar.xz "
if [ "$HAVE_RPM" = 1 ]; then
  expect_eq "config: rpm uses its own zstd" "$(rpm -qp --qf '%{PAYLOADCOMPRESSOR}' "$WORK/mixed/hello-1.0.0-1.noarch.rpm")" "zstd"
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
  "contents": [
    { "src": "tool.sh", "dst": "/usr/bin/relations-tool", "mode": "0755" },
    { "dst": "/var/lib/relations", "type": "dir", "mode": "0750", "owner": "daemon", "group": "daemon" },
    { "src": "tool.sh", "dst": "/etc/relations.conf", "type": "config", "mode": "0640", "owner": "root", "group": "daemon" }
  ]
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
DEB_LIST="$(dpkg-deb --contents "$RDEB")"
expect_in "deb owner and mode of the directory" "drwxr-x--- daemon/daemon" "$DEB_LIST"
expect_in "deb owner and mode of the config file" "-rw-r----- root/daemon" "$DEB_LIST"
expect_eq "deb conffiles" "$(dpkg-deb --ctrl-tarfile "$RDEB" | tar -xO ./conffiles)" "/etc/relations.conf"
if [ "$HAVE_RPM" = 1 ]; then
  RRPM="$DEPS/out/relations-2.1.0-3.x86_64.rpm"
  [ -f "$RRPM" ] || die "expected $RRPM"
  RPM_LIST="$(rpm -qlvp "$RRPM")"
  expect_in "rpm owner and mode of the directory" "drwxr-x---    2 daemon   daemon" "$RPM_LIST"
  expect_in "rpm owner and mode of the config file" "-rw-r-----    1 root     daemon" "$RPM_LIST"
  expect_eq "rpm config files" "$(rpm -qcp "$RRPM")" "/etc/relations.conf"
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

# ---------------------------------------------------------------- repositories
step "repo: apt flat repository and dnf repodata"
REPOD="$WORK/repo"
mkdir -p "$REPOD/deb" "$REPOD/rpm" "$REPOD/demo"
printf '#!/bin/sh\necho demo from linuxpkg\n' >"$REPOD/demo/demo.sh"
cat >"$REPOD/demo/linuxpkg.json" <<'JSON'
{
  "name": "linuxpkg-demo",
  "version": "2.0",
  "arch": "all",
  "maintainer": "Demo <demo@example.org>",
  "description": "Demo package\nDepends on hello so that the index has to resolve it.",
  "mtime": 1700000000,
  "depends": ["hello (>= 1.0)"],
  "contents": [{ "src": "demo.sh", "dst": "/usr/bin/linuxpkg-demo", "mode": "0755" }]
}
JSON
"$BIN" build "$EXAMPLE" --format deb --compression zstd --out "$REPOD/deb"
"$BIN" build "$REPOD/demo/linuxpkg.json" --format deb --compression xz --out "$REPOD/deb"
"$BIN" repo "$REPOD/deb" --format deb
expect_in "Release has a Date" "Date: " "$(cat "$REPOD/deb/Release")"
expect_in "Packages lists the demo" "Filename: ./linuxpkg-demo_2.0-1_all.deb" "$(cat "$REPOD/deb/Packages")"
if command -v apt-ftparchive >/dev/null 2>&1; then
  # The same stanzas as apt-ftparchive writes (it orders the fields its own way
  # and adds a SHA512 line), compared field by field.
  (cd "$REPOD/deb" && apt-ftparchive packages .) >"$WORK/ref-Packages"
  python3 - "$WORK/ref-Packages" "$REPOD/deb/Packages" <<'PY'
import sys
def stanzas(path):
    out = {}
    for block in open(path, encoding="utf-8").read().split("\n\n"):
        if not block.strip():
            continue
        fields, key = {}, None
        for line in block.split("\n"):
            if line.startswith(" "):
                fields[key] += "\n" + line
            else:
                key, value = line.split(":", 1)
                fields[key] = value
        out[fields["Package"].strip()] = fields
    return out
ref, ours = stanzas(sys.argv[1]), stanzas(sys.argv[2])
assert sorted(ref) == sorted(ours), (sorted(ref), sorted(ours))
for name in ref:
    r = dict(ref[name]); r.pop("SHA512", None)
    assert r == ours[name], (name, r, ours[name])
print("  ok: Packages has the same fields and values as apt-ftparchive's (except its SHA512) for %d packages" % len(ref))
PY
fi
xz -t "$REPOD/deb/Packages.xz" 2>/dev/null && pass "xz -t accepts Packages.xz" || echo "  xz not installed, skipped"
gzip -t "$REPOD/deb/Packages.gz" && pass "gzip -t accepts Packages.gz"
APT_OPTS="-o Dir::Etc::sourcelist=$WORK/repo.list -o Dir::Etc::sourceparts=/dev/null -o Dir::State::lists=$WORK/apt-lists -o Dir::Cache=$WORK/apt-cache"
echo "deb [trusted=yes] file:$REPOD/deb ./" >"$WORK/repo.list"
mkdir -p "$WORK/apt-lists/partial" "$WORK/apt-cache/archives/partial"
$SUDO apt-get $APT_OPTS update >"$WORK/apt-update.txt" 2>&1 || { cat "$WORK/apt-update.txt"; die "apt-get update failed"; }
expect_in "apt sees the demo package" "linuxpkg-demo" "$(apt-cache $APT_OPTS policy linuxpkg-demo)"
$SUDO apt-get $APT_OPTS install -y linuxpkg-demo >"$WORK/apt-install.txt" 2>&1 || { cat "$WORK/apt-install.txt"; die "apt-get install failed"; }
expect_eq "apt installed hello as a dependency" "$(/usr/bin/hello)" "hello from linuxpkg"
expect_eq "apt installed the demo" "$(/usr/bin/linuxpkg-demo)" "demo from linuxpkg"
$SUDO apt-get $APT_OPTS remove -y linuxpkg-demo hello >/dev/null 2>&1
$SUDO dpkg -P hello linuxpkg-demo >/dev/null 2>&1 || true
[ ! -e /usr/bin/linuxpkg-demo ] || die "demo still installed"
pass "apt-get update / install (with a dependency) / remove work against the generated repository"
if [ "$HAVE_RPM" = 1 ]; then
  "$BIN" build "$EXAMPLE" --format rpm --compression zstd --out "$REPOD/rpm"
  "$BIN" build "$REPOD/demo/linuxpkg.json" --format rpm --compression xz --out "$REPOD/rpm"
  "$BIN" build "$DEPS/linuxpkg.json" --format rpm --out "$REPOD/rpm"
  "$BIN" repo "$REPOD/rpm" --format rpm
  [ -f "$REPOD/rpm/repodata/repomd.xml" ] || die "repomd.xml missing"
  if command -v createrepo_c >/dev/null 2>&1; then
    mkdir -p "$REPOD/ref" && cp "$REPOD"/rpm/*.rpm "$REPOD/ref/"
    createrepo_c --no-database "$REPOD/ref" >/dev/null 2>&1
    python3 - "$REPOD/ref/repodata" "$REPOD/rpm/repodata" <<'PY'
import glob, gzip, re, sys
def blocks(path):
    text = gzip.open(path, "rt", encoding="utf-8").read()
    text = re.sub(r'<time file="[0-9]+"', '<time file="T"', text)
    out = {}
    for part in re.split(r'(?=<package[ >])', text)[1:]:
        part = re.sub(r'</(metadata|filelists|otherdata)>\s*$', '', part).strip()
        name = re.search(r'<name>([^<]*)</name>|name="([^"]*)"', part)
        out[name.group(1) or name.group(2)] = part
    return out
for kind in ("primary", "filelists", "other"):
    ref = blocks(glob.glob(sys.argv[1] + "/*-" + kind + ".xml.gz")[0])
    ours = blocks(glob.glob(sys.argv[2] + "/*-" + kind + ".xml.gz")[0])
    assert sorted(ref) == sorted(ours), (kind, sorted(ref), sorted(ours))
    for name in ref:
        assert ref[name] == ours[name], "%s of %s differs from createrepo_c:\n%s\n----\n%s" % (kind, name, ref[name], ours[name])
    print("  ok: %s.xml for %d packages is identical to createrepo_c's" % (kind, len(ref)))
PY
  fi
fi

# ---------------------------------------------------------------- arch linux
if command -v bsdtar >/dev/null 2>&1; then
  step "arch: packages for pacman, read back with bsdtar (libarchive, pacman's own reader)"
  AR="$WORK/arch"
  mkdir -p "$AR"
  for COMP in zstd xz gzip none; do
    "$BIN" build "$EXAMPLE" --format arch --compression "$COMP" --out "$AR/$COMP" >/dev/null
    PKG="$(ls "$AR/$COMP"/hello-1.0.0-1-any.pkg.tar*)"
    LIST="$(bsdtar -tf "$PKG")"
    expect_eq "$COMP: first entries" "$(printf '%s\n' "$LIST" | head -n 3 | tr '\n' ' ')" ".INSTALL .MTREE .PKGINFO "
    expect_in "$COMP: program listed" "usr/bin/hello" "$LIST"
    expect_in "$COMP: directories have a trailing slash" "usr/bin/" "$LIST"
    "$BIN" verify "$PKG" >/dev/null
    pass "$COMP: our verify accepts the package"
  done
  PKG="$(ls "$AR"/zstd/hello-1.0.0-1-any.pkg.tar*)"
  if command -v zstd >/dev/null 2>&1; then zstd -t "$PKG" >/dev/null && pass "zstd -t accepts the package"; fi
  mkdir "$AR/extract"
  bsdtar -xpf "$PKG" -C "$AR/extract"
  cmp "$AR/extract/usr/bin/hello" examples/hello/hello.sh
  cmp "$AR/extract/etc/hello.conf" examples/hello/hello.conf
  expect_eq "extracted symlink" "$(readlink "$AR/extract/usr/bin/hi")" "hello"
  pass "bsdtar extracts files identical to the sources"
  PKGINFO="$(bsdtar -xOf "$PKG" .PKGINFO)"
  expect_in ".PKGINFO name" "pkgname = hello" "$PKGINFO"
  expect_in ".PKGINFO version" "pkgver = 1.0.0-1" "$PKGINFO"
  expect_in ".PKGINFO arch" "arch = any" "$PKGINFO"
  expect_in ".PKGINFO backup" "backup = etc/hello.conf" "$PKGINFO"
  expect_in ".PKGINFO license" "license = Apache-2.0" "$PKGINFO"
  INSTALL="$(bsdtar -xOf "$PKG" .INSTALL)"
  bash -n <(printf '%s\n' "$INSTALL") && pass ".INSTALL is valid bash"
  expect_in ".INSTALL post_install" "post_install()" "$INSTALL"
  expect_in ".INSTALL post_upgrade" "post_upgrade()" "$INSTALL"
  # The .MTREE must say the same as bsdtar's own mtree of the extracted tree.
  bsdtar -xOf "$PKG" .MTREE | gzip -dc >"$AR/ours.mtree"
  (cd "$AR/extract" && bsdtar -cf - --format=mtree --options='!all,use-set,type,mode,size,sha256,link' .) >"$AR/ref.mtree"
  python3 - "$AR/ours.mtree" "$AR/ref.mtree" <<'PY'
import re, sys
def parse(path):
    defaults, out = {}, {}
    for line in open(path, encoding="utf-8").read().splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts[0] == "/set":
            defaults.update(p.split("=", 1) for p in parts[1:])
            continue
        if parts[0] == "/unset":
            for k in parts[1:]:
                defaults.pop(k, None)
            continue
        name = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), parts[0])
        if name in (".", "./"):
            continue
        values = dict(defaults)
        values.update(p.split("=", 1) for p in parts[1:] if "=" in p)
        out[name] = {k: values.get(k) for k in ("type", "mode", "size", "sha256digest", "link")}
    return out
ours, ref = parse(sys.argv[1]), parse(sys.argv[2])
# Ours lists .PKGINFO and .INSTALL, which bsdtar also sees in the extracted tree.
missing = [n for n in ours if n not in ref]
assert not missing, ("not found by bsdtar", missing)
for name, values in ours.items():
    want = ref[name]
    # bsdtar leaves type=file out when it is the default.
    for key in values:
        got, exp = values[key], want[key]
        if key == "type":
            got, exp = got or "file", exp or "file"
        assert got == exp, (name, key, got, exp)
print("  ok: .MTREE agrees with bsdtar's mtree of the extracted tree on %d entries" % len(ours))
PY
fi

# ---------------------------------------------------------------- alpine linux
step "apk: Alpine packages, read back with Python's tarfile and (if present) apk"
APKD="$WORK/apk"
mkdir -p "$APKD"
"$BIN" build "$EXAMPLE" --format apk --out "$APKD" >/dev/null
APKFILE="$APKD/hello-1.0.0-r1.apk"
[ -f "$APKFILE" ] || die "expected $APKFILE"
python3 - "$APKFILE" <<'PY'
import sys, zlib, tarfile, io, hashlib
data = open(sys.argv[1], "rb").read()
members, pos = [], 0
while pos < len(data):
    d = zlib.decompressobj(31)
    out = d.decompress(data[pos:])
    used = len(data[pos:]) - len(d.unused_data)
    members.append((data[pos:pos + used], out))
    pos += used
assert len(members) == 2, len(members)
control = tarfile.open(fileobj=io.BytesIO(members[0][1]))
names = control.getnames()
assert names[0] == ".PKGINFO", names
assert members[0][1][-1024:] != b"\0" * 1024, "the control segment must not end with the tar end marker"
info = dict(l.split(" = ", 1) for l in control.extractfile(".PKGINFO").read().decode().splitlines() if " = " in l)
assert info["pkgname"] == "hello" and info["pkgver"] == "1.0.0-r1" and info["arch"] == "noarch", info
assert info["datahash"] == hashlib.sha256(members[1][0]).hexdigest(), "datahash is not the sha256 of the data stream"
data_tar = tarfile.open(fileobj=io.BytesIO(members[1][1]))
checked = 0
for m in data_tar:
    sums = m.pax_headers.get("APK-TOOLS.checksum.SHA1")
    if m.isreg():
        assert sums == hashlib.sha1(data_tar.extractfile(m).read()).hexdigest(), m.name
        checked += 1
    elif m.issym():
        assert sums == hashlib.sha1(m.linkname.encode()).hexdigest(), m.name
        checked += 1
    else:
        assert sums is None, m.name
assert checked == 4, checked
assert members[1][1][-1024:] == b"\0" * 1024
print("  ok: tarfile reads both segments; datahash and %d SHA-1 records are right" % checked)
PY
"$BIN" verify "$APKFILE" >/dev/null
pass "our verify accepts the apk"
APK_TOOL="${APK:-$(command -v apk || true)}"
if [ -n "$APK_TOOL" ] && [ -x "$APK_TOOL" ]; then
  AROOT="$WORK/apk-root"
  mkdir -p "$AROOT"
  "$APK_TOOL" --root "$AROOT" --initdb --allow-untrusted --no-network --no-cache --no-scripts add "$APKFILE" >"$WORK/apk-add.txt" 2>&1 || { cat "$WORK/apk-add.txt"; die "apk add failed"; }
  if grep -qi "warning\|error" "$WORK/apk-add.txt"; then cat "$WORK/apk-add.txt"; die "apk add warned"; fi
  expect_eq "apk installed program" "$("$AROOT/usr/bin/hello")" "hello from linuxpkg"
  expect_eq "apk installed symlink" "$(readlink "$AROOT/usr/bin/hi")" "hello"
  expect_in "apk info lists the files" "usr/bin/hello" "$("$APK_TOOL" --root "$AROOT" info -L hello)"
  AUDIT="$("$APK_TOOL" --root "$AROOT" audit --full 2>&1 | grep -v '^D lib/' || true)"
  [ -z "$AUDIT" ] || { echo "$AUDIT"; die "apk audit found differences"; }
  pass "apk add installs the package and apk audit finds no differences"
else
  echo "  apk is not installed, the install check is left to the container job"
fi

# ---------------------------------------------------------------- self-hosting
step "linuxpkg packages itself (examples/self)"
SELF_TARGET="${TARGET_DIR:-$ROOT/_build}"
moon build --target native --release --target-dir "$SELF_TARGET" cmd/main
RELEASE_BIN="$(find "$SELF_TARGET/native/release" -name main.exe -path '*cmd/main*' | head -n 1)"
[ -x "$RELEASE_BIN" ] || die "release binary not found"
VERSION="$("$RELEASE_BIN" --version | awk '{print $2}')"
SELF_VERSION="$(python3 -c "import json;print(json.load(open('examples/self/linuxpkg.json'))['version'])")"
expect_eq "examples/self version matches VERSION" "$SELF_VERSION" "$VERSION"
python3 - "$RELEASE_BIN" "$ROOT" "$WORK/self.json" <<'PY'
import json, sys
binary, root, out = sys.argv[1:4]
config = json.load(open(root + "/examples/self/linuxpkg.json"))
for item in config["contents"]:
    if item["dst"] == "/usr/bin/linuxpkg":
        item["src"] = binary
    else:
        item["src"] = root + "/" + item["src"].replace("../../", "")
json.dump(config, open(out, "w"), indent=2)
PY
"$BIN" build "$WORK/self.json" --out "$WORK/self"
SELF_DEB="$WORK/self/linuxpkg_${VERSION}-1_amd64.deb"
[ -f "$SELF_DEB" ] || die "expected $SELF_DEB"
$SUDO dpkg -i "$SELF_DEB"
expect_eq "installed linuxpkg --version" "$(linuxpkg --version)" "linuxpkg $VERSION"
# The installed copy builds, inspects and verifies packages like the original.
linuxpkg build "$EXAMPLE" --out "$WORK/by-installed"
cmp "$DEB" "$WORK/by-installed/hello_1.0.0-1_all.deb"
linuxpkg verify "$SELF_DEB"
pass "the installed linuxpkg builds the same hello deb and verifies its own package"
$SUDO dpkg -r linuxpkg
[ ! -e /usr/bin/linuxpkg ] || die "linuxpkg still installed"
if [ "$HAVE_RPM" = 1 ]; then
  SELF_RPM="$WORK/self/linuxpkg-${VERSION}-1.x86_64.rpm"
  rpm -K --nosignature "$SELF_RPM" | grep -q "digests OK" || die "rpm -K failed for the self package"
  "$BIN" verify "$SELF_RPM"
  mkdir "$WORK/self-extract"
  (cd "$WORK/self-extract" && rpm2cpio "$SELF_RPM" | cpio -idm --quiet)
  expect_eq "rpm payload runs" "$("$WORK/self-extract/usr/bin/linuxpkg" --version)" "linuxpkg $VERSION"
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
