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
      dnf install -y --disablerepo="*" /pkgs/$c/hello-1.0.0-1.noarch.rpm
      test "$(hello)" = "hello from linuxpkg"
      dnf remove -y --disablerepo="*" hello
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

real_rpm() { # image package [url]
  # With a URL the package is downloaded here, on the host: dnf in the
  # openEuler image needs many minutes to load its repository metadata.
  local image="$1" pkg="$2" url="${3:-}"
  step "$image: linuxpkg reads and verifies the distribution's own $pkg rpm"
  local dir="$WORK/real-$(echo "$image" | tr ':/' '__')"
  mkdir -p "$dir"
  local fetch='dnf download --destdir /out '"$pkg"' || { dnf install -y dnf-plugins-core && dnf download --destdir /out '"$pkg"'; }'
  if [ -n "$url" ]; then
    if ! curl -fsSL --retry 3 -m 300 -o "$dir/$(basename "$url")" "$url"; then
      echo "NOTE: could not download $url, this check is skipped"
      return 0
    fi
    fetch=':'
  fi
  docker run --rm -v "$dir:/out" "$image" bash -ec '
    '"$fetch"'
    f=$(ls /out/'"$pkg"'-*.rpm | head -n 1)
    {
      rpm -qp --qf "name=%{NAME}\nversion=%{VERSION}\nrelease=%{RELEASE}\narch=%{ARCH}\ncompressor=%{PAYLOADCOMPRESSOR}\n" "$f"
      echo "files=$(rpm -qlp "$f" | wc -l)"
    } > /out/expected.txt
    rpm -qlp "$f" > /out/files.txt
    rpm -K "$f" || true
    chmod a+rw /out/*
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

# A second package that depends on hello, so that installing it from the
# generated repository has to resolve a dependency through the index.
mkdir -p "$WORK/demo"
printf '#!/bin/sh\necho demo from linuxpkg\n' >"$WORK/demo/demo.sh"
cat >"$WORK/demo/linuxpkg.json" <<'JSON'
{
  "name": "linuxpkg-demo",
  "version": "2.0",
  "arch": "all",
  "maintainer": "Demo <demo@example.org>",
  "description": "Demo package\nDepends on hello so that the repository index has to resolve it.",
  "mtime": 1700000000,
  "depends": ["hello (>= 1.0)"],
  "contents": [{ "src": "demo.sh", "dst": "/usr/bin/linuxpkg-demo", "mode": "0755" }]
}
JSON

step "building the package repositories (apt flat repository and dnf repodata)"
mkdir -p "$WORK/repo-deb" "$WORK/repo-rpm"
"$BIN" build examples/hello/linuxpkg.json --format deb --compression zstd --out "$WORK/repo-deb"
"$BIN" build "$WORK/demo/linuxpkg.json" --format deb --compression xz --out "$WORK/repo-deb"
"$BIN" build examples/hello/linuxpkg.json --format rpm --compression zstd --out "$WORK/repo-rpm"
"$BIN" build "$WORK/demo/linuxpkg.json" --format rpm --compression xz --out "$WORK/repo-rpm"
"$BIN" repo "$WORK/repo-deb"
"$BIN" repo "$WORK/repo-rpm"
# Running it again must not change a byte.
cp -r "$WORK/repo-deb" "$WORK/repo-deb.1"
cp -r "$WORK/repo-rpm" "$WORK/repo-rpm.1"
"$BIN" repo "$WORK/repo-deb" >/dev/null
"$BIN" repo "$WORK/repo-rpm" >/dev/null
diff -r "$WORK/repo-deb" "$WORK/repo-deb.1"
diff -r "$WORK/repo-rpm" "$WORK/repo-rpm.1"
chmod -R a+rX "$WORK/repo-deb" "$WORK/repo-rpm"

repo_deb() { # image
  local image="$1"
  step "$image: apt-get install from the generated repository"
  docker run --rm -v "$WORK/repo-deb:/repo:ro" "$image" bash -ec '
    echo "deb [trusted=yes] file:/repo ./" > /etc/apt/linuxpkg.list
    O="-o Dir::Etc::sourcelist=/etc/apt/linuxpkg.list -o Dir::Etc::sourceparts=/dev/null"
    apt-get $O update
    apt-get $O install -y linuxpkg-demo
    test "$(hello)" = "hello from linuxpkg"
    test "$(linuxpkg-demo)" = "demo from linuxpkg"
    dpkg -s linuxpkg-demo | grep -q "^Depends: hello (>= 1.0)"
    apt-get $O remove -y linuxpkg-demo hello
    test ! -e /usr/bin/linuxpkg-demo
    echo "apt repository check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

repo_rpm() { # image
  local image="$1"
  step "$image: dnf install from the generated repository"
  docker run --rm -v "$WORK/repo-rpm:/repo:ro" "$image" bash -ec '
    cat > /etc/yum.repos.d/linuxpkg.repo <<REPO
[linuxpkg]
name=linuxpkg
baseurl=file:///repo
enabled=1
gpgcheck=0
REPO
    dnf --disablerepo="*" --enablerepo=linuxpkg makecache
    dnf --disablerepo="*" --enablerepo=linuxpkg repoquery --qf "%{name} %{version}-%{release}.%{arch}" "*" | sort
    dnf --disablerepo="*" --enablerepo=linuxpkg install -y linuxpkg-demo
    test "$(hello)" = "hello from linuxpkg"
    test "$(linuxpkg-demo)" = "demo from linuxpkg"
    rpm -q --requires linuxpkg-demo | grep -q "hello >= 1.0"
    dnf remove -y linuxpkg-demo hello
    test ! -e /usr/bin/linuxpkg-demo
    echo "dnf repository check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

# ---- Arch Linux: pacman installs the packages, makepkg and the mirrors give references
arch_check() {
  step "archlinux:latest: pacman -U, -Qkk, -R for ${COMPRESSIONS}"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" archlinux:latest bash -ec '
    for c in '"$COMPRESSIONS"'; do
      echo "-- $c"
      f=$(ls /pkgs/$c/hello-1.0.0-1-any.pkg.tar*)
      pacman -U --noconfirm "$f"
      test "$(hello)" = "hello from linuxpkg"
      test "$(hi)" = "hello from linuxpkg"
      test "$(cat /var/lib/hello/state)" = installed
      test -f /etc/hello.conf
      test "$(pacman -Q hello)" = "hello 1.0.0-1"
      pacman -Qi hello | tee /tmp/qi.txt
      grep -qi "^Architecture *: any" /tmp/qi.txt
      grep -q "^Licenses *: Apache-2.0" /tmp/qi.txt
      grep -q "^URL *: https://github.com/pxgt/linuxpkg" /tmp/qi.txt
      pacman -Ql hello
      pacman -Qkk hello | tee /tmp/qkk.txt
      grep -q " 0 altered files" /tmp/qkk.txt
      pacman -Qo /usr/bin/hello
      pacman -R --noconfirm hello
      test ! -e /usr/bin/hello
      test ! -e /var/lib/hello/state
    done
    echo "pacman check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

arch_real() {
  step "archlinux:latest: linuxpkg reads and verifies packages made by makepkg and by Arch's build servers"
  local dir="$WORK/real-arch"
  mkdir -p "$dir"
  docker run --rm -v "$dir:/out" -v "$ROOT/examples/hello:/hello:ro" archlinux:latest bash -ec '
    # Docker hosts without Landlock cannot run pacman 7 with its download sandbox.
    p() { pacman "$@" || pacman --disable-sandbox "$@"; }
    p -Sy --noconfirm >/dev/null
    p -Sw --noconfirm --cachedir /out which tree
    p -S --noconfirm --needed fakeroot binutils file >/dev/null
    useradd -m builder
    mkdir -p /home/builder/pkg
    cp -r /hello/. /home/builder/pkg/files
    cat > /home/builder/pkg/PKGBUILD <<EOF
pkgname=makepkg-hello
pkgver=1.0
pkgrel=1
pkgdesc="Built by the real makepkg"
arch=(any)
options=(!strip !debug)
url="https://example.org/makepkg-hello"
license=(MIT)
depends=(bash)
optdepends=("less: pager")
backup=(etc/makepkg-hello.conf)
install=makepkg-hello.install
package() {
  install -Dm755 "\$srcdir/../files/hello.sh" "\$pkgdir/usr/bin/makepkg-hello"
  install -Dm644 "\$srcdir/../files/hello.conf" "\$pkgdir/etc/makepkg-hello.conf"
  ln -s makepkg-hello "\$pkgdir/usr/bin/mh"
}
EOF
    printf "post_install() {\n  echo installed\n}\n" > /home/builder/pkg/makepkg-hello.install
    chown -R builder /home/builder
    su builder -c "cd /home/builder/pkg && makepkg -f --nodeps --skipinteg"
    cp /home/builder/pkg/*.pkg.tar.zst /out/
    cd /out
    for f in which-*.pkg.tar.zst tree-*.pkg.tar.zst makepkg-hello-*.pkg.tar.zst; do
      n=${f%%.pkg.tar.zst}
      {
        pacman -Qip "$f" | awk -F" *: " "/^Name|^Version|^Architecture/ {print tolower(\$1)\"=\"\$2}"
        echo "files=$(pacman -Qlp "$f" | wc -l)"
      } > "$n.expected"
      pacman -Qlp "$f" | awk "{print \$2}" > "$n.files"
    done
    chmod a+rw /out/*
  '
  local f
  for f in "$dir"/which-*.pkg.tar.zst "$dir"/tree-*.pkg.tar.zst "$dir"/makepkg-hello-*.pkg.tar.zst; do
    "$BIN" inspect "$f"
    "$BIN" inspect "$f" --json >"$dir/report.json"
    python3 - "$dir/report.json" "${f%.pkg.tar.zst}.expected" "${f%.pkg.tar.zst}.files" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
expected = dict(line.split("=", 1) for line in open(sys.argv[2]).read().splitlines())
files = sorted(l for l in open(sys.argv[3]).read().splitlines() if l)
version = report["version"] + "-" + report["release"]
if report["epoch"] is not None:
    version = "%d:%s" % (report["epoch"], version)
assert report["name"] == expected["name"], (report["name"], expected["name"])
assert version == expected["version"], (version, expected["version"])
assert report["architecture"].lower() == expected["architecture"].lower(), (report["architecture"], expected["architecture"])
ours = sorted(f["path"] for f in report["files"])
# pacman -Qlp lists directories with a trailing slash.
theirs = sorted(p.rstrip("/") or "/" for p in files if not p.rsplit("/", 1)[-1].startswith(".") or True)
theirs = [p for p in theirs if p not in ("/.PKGINFO", "/.MTREE", "/.BUILDINFO", "/.INSTALL")]
assert ours == theirs, (ours, theirs)
print("  ok: name, version, architecture and %d file names agree with pacman -Qip / -Qlp" % len(ours))
PY
    "$BIN" verify "$f" | tee "$dir/verify.out"
    grep -q "OK (" "$dir/verify.out" || die "$f: verify did not report OK"
    echo "  ok: $(basename "$f") verified in full (exit 0)"
  done
  # The package makepkg built installs and removes cleanly, with its .INSTALL.
  docker run --rm -v "$dir:/out:ro" archlinux:latest bash -ec '
    pacman -U --noconfirm /out/makepkg-hello-*.pkg.tar.zst
    test -x /usr/bin/makepkg-hello
    pacman -Qkk makepkg-hello
    pacman -R --noconfirm makepkg-hello
  '
  docker run --rm -v "$dir:/out" archlinux:latest sh -c 'rm -rf /out/*'
}

run_deb debian:12
run_deb ubuntu:24.04
run_rpm fedora:41
arch_check
arch_real
repo_deb debian:12
repo_deb ubuntu:24.04
repo_rpm fedora:41

real_deb debian:12 xz
real_deb ubuntu:24.04 zstd
real_rpm fedora:41 hello

OPENEULER="openeuler/openeuler:24.03-lts"
if docker pull "$OPENEULER" >/dev/null 2>&1; then
  run_rpm "$OPENEULER"
  repo_rpm "$OPENEULER"
  real_rpm "$OPENEULER" tree "https://repo.openeuler.org/openEuler-24.03-LTS/everything/x86_64/Packages/tree-2.1.1-1.oe2403.x86_64.rpm"
else
  echo "NOTE: $OPENEULER could not be pulled, using rockylinux:9 as the RPM-family substitute"
  run_rpm rockylinux:9
  repo_rpm rockylinux:9
  real_rpm rockylinux:9 tree
fi

printf '\nAll container checks passed.\n'
