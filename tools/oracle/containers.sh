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

# ---- signed repositories: no [trusted=yes], the package manager checks the signature
step "building signed repositories (test-only RSA and Ed25519 keys)"
for k in rsa2048 ed25519; do
  mkdir -p "$WORK/signed-deb-$k" "$WORK/signed-rpm-$k"
  cp "$WORK"/repo-deb/*.deb "$WORK/signed-deb-$k/"
  # The rpm packages carry their own signature too (gpgcheck=1 needs it).
  "$BIN" build examples/hello/linuxpkg.json --format rpm --compression zstd --out "$WORK/signed-rpm-$k" --sign-key "testdata/sign/test-only-$k.sec.asc" >/dev/null
  "$BIN" build "$WORK/demo/linuxpkg.json" --format rpm --compression xz --out "$WORK/signed-rpm-$k" --sign-key "testdata/sign/test-only-$k.sec.asc" >/dev/null
  # Arch packages with a detached signature next to them.
  "$BIN" build examples/hello/linuxpkg.json --format arch --out "$WORK/signed-arch-$k" --sign-key "testdata/sign/test-only-$k.sec.asc" >/dev/null
  "$BIN" repo "$WORK/signed-deb-$k" --format deb --sign-key "testdata/sign/test-only-$k.sec.asc"
  "$BIN" repo "$WORK/signed-rpm-$k" --format rpm --sign-key "testdata/sign/test-only-$k.sec.asc"
  mkdir -p "$WORK/keys-$k"
  cp "testdata/sign/test-only-$k.pub.asc" "$WORK/keys-$k/key.asc"
done
chmod -R a+rX "$WORK"/signed-deb-* "$WORK"/signed-rpm-* "$WORK"/signed-arch-* "$WORK"/keys-*

signed_deb() { # image key
  local image="$1" key="$2"
  step "$image: apt with signed-by accepts the $key repository and refuses a changed one"
  docker run --rm -v "$WORK/signed-deb-$key:/repo:ro" -v "$WORK/keys-$key:/keys:ro" "$image" bash -ec '
    mkdir -p /etc/apt/keyrings
    cp /keys/key.asc /etc/apt/keyrings/linuxpkg.asc
    echo "deb [signed-by=/etc/apt/keyrings/linuxpkg.asc] file:/repo ./" > /etc/apt/linuxpkg.list
    O="-o Dir::Etc::sourcelist=/etc/apt/linuxpkg.list -o Dir::Etc::sourceparts=/dev/null"
    apt-get $O update
    apt-get $O install -y linuxpkg-demo
    test "$(hello)" = "hello from linuxpkg"
    test "$(linuxpkg-demo)" = "demo from linuxpkg"
    apt-get $O remove -y linuxpkg-demo hello
    # A repository whose Release was changed after signing must be refused.
    cp -r /repo /tmp/bad
    sed -i "s/^Date: .*/Date: Tue, 14 Nov 2023 22:13:21 +0000/" /tmp/bad/Release /tmp/bad/InRelease
    echo "deb [signed-by=/etc/apt/keyrings/linuxpkg.asc] file:/tmp/bad ./" > /etc/apt/linuxpkg-bad.list
    rm -rf /var/lib/apt/lists/*
    if apt-get -o Dir::Etc::sourcelist=/etc/apt/linuxpkg-bad.list -o Dir::Etc::sourceparts=/dev/null update 2>&1 | tee /tmp/bad.txt; then
      if ! grep -q "^E:" /tmp/bad.txt; then echo "apt accepted a changed repository"; exit 1; fi
    fi
    grep -E "not signed|BADSIG|invalid" /tmp/bad.txt
    # Without the key apt refuses the genuine repository too.
    echo "deb file:/repo ./" > /etc/apt/linuxpkg-nokey.list
    rm -rf /var/lib/apt/lists/*
    apt-get -o Dir::Etc::sourcelist=/etc/apt/linuxpkg-nokey.list -o Dir::Etc::sourceparts=/dev/null update 2>&1 | tee /tmp/nokey.txt || true
    grep -E "NO_PUBKEY|not signed" /tmp/nokey.txt
    echo "signed apt repository check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

signed_rpm() { # image key
  local image="$1" key="$2"
  step "$image: dnf with gpgcheck=1 and repo_gpgcheck=1 accepts the $key repository and refuses changed or unsigned ones"
  docker run --rm -v "$WORK/signed-rpm-$key:/repo:ro" -v "$WORK/repo-rpm:/unsigned:ro" -v "$WORK/keys-$key:/keys:ro" "$image" bash -ec '
    cat > /etc/yum.repos.d/linuxpkg.repo <<REPO
[linuxpkg]
name=linuxpkg
baseurl=file:///repo
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///keys/key.asc
REPO
    dnf -y --disablerepo="*" --enablerepo=linuxpkg makecache
    dnf -y --disablerepo="*" --enablerepo=linuxpkg install linuxpkg-demo
    test "$(hello)" = "hello from linuxpkg"
    test "$(linuxpkg-demo)" = "demo from linuxpkg"
    # The packages themselves are signed: rpm checks them with the imported key.
    rpm -q gpg-pubkey | grep -q gpg-pubkey
    rpm -K /repo/hello-1.0.0-1.noarch.rpm | tee /tmp/k.txt
    grep -q "signatures OK" /tmp/k.txt
    rpm -qi hello | grep -E "^Signature"
    dnf remove -y linuxpkg-demo hello
    # repomd.xml changed after signing: dnf must refuse it.
    cp -r /repo /tmp/bad
    printf " " >> /tmp/bad/repodata/repomd.xml
    sed -i "s#file:///repo#file:///tmp/bad#" /etc/yum.repos.d/linuxpkg.repo
    dnf clean all
    if dnf -y --disablerepo="*" --enablerepo=linuxpkg install linuxpkg-demo >/tmp/bad.txt 2>&1; then
      cat /tmp/bad.txt; echo "dnf installed from a changed repository"; exit 1
    fi
    cat /tmp/bad.txt
    grep -iE "GPG signature verification error" /tmp/bad.txt
    test ! -e /usr/bin/linuxpkg-demo
    # Packages without a signature are refused when gpgcheck=1 (no repo_gpgcheck here).
    sed -i "s#file:///tmp/bad#file:///unsigned#; s#^repo_gpgcheck=1#repo_gpgcheck=0#" /etc/yum.repos.d/linuxpkg.repo
    dnf clean all
    if dnf -y --disablerepo="*" --enablerepo=linuxpkg install linuxpkg-demo >/tmp/unsigned.txt 2>&1; then
      cat /tmp/unsigned.txt; echo "dnf installed an unsigned package with gpgcheck=1"; exit 1
    fi
    cat /tmp/unsigned.txt
    grep -iE "not signed|GPG|signature" /tmp/unsigned.txt
    test ! -e /usr/bin/linuxpkg-demo
    echo "signed dnf repository check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

signed_arch() { # key
  local key="$1"
  step "archlinux:latest: pacman with LocalFileSigLevel = Required installs the $key-signed package and refuses damaged ones"
  local fpr
  fpr="$(awk -v k="$key" '$1==k {print $2}' testdata/sign/fingerprints.txt)"
  docker run --rm -e "FPR=$fpr" -v "$WORK/signed-arch-$key:/pkgs:ro" -v "$WORK/keys-$key:/keys:ro" archlinux:latest bash -ec '
    sed -i "/^NoExtract/d" /etc/pacman.conf
    pacman-key --init
    pacman-key --add /keys/key.asc
    pacman-key --lsign-key "$FPR"
    sed -i "s/^#\?LocalFileSigLevel.*/LocalFileSigLevel = Required/" /etc/pacman.conf
    grep -q "^LocalFileSigLevel = Required" /etc/pacman.conf || echo "LocalFileSigLevel = Required" >> /etc/pacman.conf
    f=$(ls /pkgs/hello-1.0.0-1-any.pkg.tar.zst)
    # A package without its signature is refused.
    mkdir -p /tmp/nosig && cp "$f" /tmp/nosig/
    if pacman -U --noconfirm /tmp/nosig/hello-1.0.0-1-any.pkg.tar.zst >/tmp/nosig.txt 2>&1; then cat /tmp/nosig.txt; echo "pacman accepted an unsigned package"; exit 1; fi
    cat /tmp/nosig.txt
    # A damaged signature is refused.
    mkdir -p /tmp/badsig && cp "$f" /tmp/badsig/ && cp "$f.sig" /tmp/badsig/
    size=$(stat -c %s /tmp/badsig/hello-1.0.0-1-any.pkg.tar.zst.sig)
    printf "x" | dd of=/tmp/badsig/hello-1.0.0-1-any.pkg.tar.zst.sig bs=1 seek=$((size - 10)) conv=notrunc 2>/dev/null
    if pacman -U --noconfirm /tmp/badsig/hello-1.0.0-1-any.pkg.tar.zst >/tmp/badsig.txt 2>&1; then cat /tmp/badsig.txt; echo "pacman accepted a damaged signature"; exit 1; fi
    cat /tmp/badsig.txt
    grep -qiE "signature|invalid or corrupted" /tmp/badsig.txt
    # The genuine package installs.
    pacman -U --noconfirm "$f"
    test "$(hello)" = "hello from linuxpkg"
    pacman -Qkk hello
    echo "signed pacman check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

# ---- Arch Linux: pacman installs the packages, makepkg and the mirrors give references
arch_check() {
  step "archlinux:latest: pacman -U, -Qkk, -R for ${COMPRESSIONS}"
  docker run --rm -v "$WORK/pkgs:/pkgs:ro" archlinux:latest bash -ec '
    # The image does not extract documentation, which would show up as missing files.
    sed -i "/^NoExtract/d" /etc/pacman.conf
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

# ---- Alpine Linux: apk installs the package, the repository gives a reference
apk_check() {
  step "alpine:3.20: apk add --allow-untrusted, audit, del"
  docker run --rm -v "$WORK/pkgs/gzip:/pkgs:ro" alpine:3.20 sh -ec '
    apk add --allow-untrusted /pkgs/hello-1.0.0-r1.apk
    test "$(hello)" = "hello from linuxpkg"
    test "$(hi)" = "hello from linuxpkg"
    test "$(cat /var/lib/hello/state)" = installed
    test -f /etc/hello.conf
    apk info -L hello
    apk info hello | head -n 3
    # Nothing of the package may differ from the checksums apk recorded.
    apk audit --full | grep -E " (usr/bin/(hello|hi)|etc/hello.conf|usr/share/doc/hello|var/lib/hello)" && exit 1
    apk del hello
    test ! -e /usr/bin/hello
    test ! -e /var/lib/hello/state
    echo "apk check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
}

signed_apk() {
  step "alpine:3.20: apk add without --allow-untrusted installs the signed package, refuses others; abuild-signed packages verify"
  local d="$WORK/signed-apk"
  mkdir -p "$d/keys" "$d/pkgs" "$d/parts"
  "$BIN" build examples/hello/linuxpkg.json --format apk --out "$d/pkgs" --sign-key testdata/sign/test-only-rsa2048.sec.asc --apk-key-name linuxpkg-test.rsa.pub >/dev/null
  "$BIN" key apk-pub testdata/sign/test-only-rsa2048.sec.asc --name linuxpkg-test --out "$d/keys" >/dev/null
  # An unsigned package split into its control and data streams, for abuild-sign.
  "$BIN" build examples/hello/linuxpkg.json --format apk --out "$d/parts" >/dev/null
  python3 - "$d/parts/hello-1.0.0-r1.apk" "$d/parts" <<'PY'
import sys, zlib
data = open(sys.argv[1], "rb").read()
members, pos = [], 0
while pos < len(data):
    d = zlib.decompressobj(31)
    d.decompress(data[pos:])
    used = len(data[pos:]) - len(d.unused_data)
    members.append(data[pos:pos + used])
    pos += used
open(sys.argv[2] + "/control.tar.gz", "wb").write(members[0])
open(sys.argv[2] + "/data.tar.gz", "wb").write(members[1])
PY
  chmod -R a+rwX "$d"
  docker run --rm -v "$d:/work" alpine:3.20 sh -ec '
    cp /work/keys/linuxpkg-test.rsa.pub /etc/apk/keys/
    apk add /work/pkgs/hello-1.0.0-r1.apk
    test "$(hello)" = "hello from linuxpkg"
    test "$(cat /var/lib/hello/state)" = installed
    apk verify /work/pkgs/hello-1.0.0-r1.apk
    apk audit --full | grep -E " (usr/bin/(hello|hi)|etc/hello.conf|usr/share/doc/hello|var/lib/hello)" && exit 1
    apk del hello
    # Without the key the package is untrusted.
    rm /etc/apk/keys/linuxpkg-test.rsa.pub
    if apk add /work/pkgs/hello-1.0.0-r1.apk >/tmp/untrusted.txt 2>&1; then cat /tmp/untrusted.txt; echo "apk installed an untrusted package"; exit 1; fi
    cat /tmp/untrusted.txt
    grep -q "UNTRUSTED signature" /tmp/untrusted.txt
    test ! -e /usr/bin/hello
    # Another key under the same name: the signature does not match.
    apk add --no-cache openssl abuild >/dev/null
    openssl genrsa -out /work/other.rsa 2048 2>/dev/null
    openssl rsa -in /work/other.rsa -pubout -out /work/other.rsa.pub 2>/dev/null
    cp /work/other.rsa.pub /etc/apk/keys/linuxpkg-test.rsa.pub
    if apk add /work/pkgs/hello-1.0.0-r1.apk >/tmp/wrongkey.txt 2>&1; then cat /tmp/wrongkey.txt; echo "apk accepted another key"; exit 1; fi
    cat /tmp/wrongkey.txt
    test ! -e /usr/bin/hello
    # A package signed by the real abuild-sign (SHA-1, .SIGN.RSA.): same layout as abuild makes it.
    cd /work/parts
    abuild-sign -k /work/other.rsa -p linuxpkg-test.rsa.pub control.tar.gz
    cat control.tar.gz data.tar.gz > /work/abuild-signed.apk
    apk add /work/abuild-signed.apk
    test "$(hello)" = "hello from linuxpkg"
    apk del hello
    chmod a+r /work/other.rsa.pub /work/abuild-signed.apk
    echo "signed apk check passed on $(. /etc/os-release && echo "$PRETTY_NAME")"
  '
  # What abuild-sign made is accepted by linuxpkg too.
  "$BIN" verify "$d/abuild-signed.apk" --keyring "$d/other.rsa.pub" | tee "$d/verify.out"
  grep -q "signature: OK" "$d/verify.out" || die "verify --keyring did not accept the abuild-signed package"
  if "$BIN" verify "$d/abuild-signed.apk" --keyring "$d/keys/linuxpkg-test.rsa.pub" >/dev/null 2>&1; then die "verify accepted the wrong key"; fi
  echo "  ok: linuxpkg verifies the abuild-signed package and refuses the wrong key"
  docker run --rm -v "$d:/work" alpine:3.20 sh -c 'rm -rf /work/*'
}

apk_real() {
  step "alpine:3.20: linuxpkg reads and verifies packages from Alpine's build servers"
  local dir="$WORK/real-alpine"
  mkdir -p "$dir"
  docker run --rm -v "$dir:/out" alpine:3.20 sh -ec '
    apk update >/dev/null
    apk fetch -o /out tree busybox-binsh >/dev/null
    apk add tree busybox-binsh >/dev/null
    for p in tree busybox-binsh; do
      f=$(ls /out/$p-*.apk)
      apk info -qL $p | sort > ${f%.apk}.files
    done
    chmod a+rw /out/*
  '
  local f
  for f in "$dir"/tree-*.apk "$dir"/busybox-binsh-*.apk; do
    "$BIN" inspect "$f"
    "$BIN" inspect "$f" --json >"$dir/report.json"
    python3 - "$dir/report.json" "${f%.apk}.files" "$(basename "$f")" <<'PY'
import json, re, sys
report = json.load(open(sys.argv[1]))
listed = sorted(l for l in open(sys.argv[2]).read().splitlines() if l)
name, version, release = re.match(r"(.+)-([0-9][^-]*)-r([0-9]+)\.apk$", sys.argv[3]).groups()
assert report["name"] == name, (report["name"], name)
assert report["version"] == version and report["release"] == release, (report["version"], report["release"])
ours = sorted(f["path"].lstrip("/") for f in report["files"] if f["type"] != "dir")
assert ours == listed, (ours, listed)
print("  ok: name, version, release and %d file names agree with apk info" % len(ours))
PY
    "$BIN" verify "$f" | tee "$dir/verify.out"
    grep -q "OK (" "$dir/verify.out" || die "$f: verify did not report OK"
    echo "  ok: $(basename "$f") verified in full (exit 0)"
  done
  docker run --rm -v "$dir:/out" alpine:3.20 sh -c 'rm -rf /out/*'
}

run_deb debian:12
run_deb ubuntu:24.04
run_rpm fedora:41
arch_check
signed_arch rsa2048
signed_arch ed25519
arch_real
apk_check
signed_apk
apk_real
repo_deb debian:12
repo_deb ubuntu:24.04
repo_rpm fedora:41
signed_deb debian:12 rsa2048
signed_deb ubuntu:24.04 ed25519
signed_rpm fedora:41 rsa2048
signed_rpm fedora:41 ed25519

real_deb debian:12 xz
real_deb ubuntu:24.04 zstd
real_rpm fedora:41 hello

OPENEULER="openeuler/openeuler:24.03-lts"
if docker pull "$OPENEULER" >/dev/null 2>&1; then
  run_rpm "$OPENEULER"
  repo_rpm "$OPENEULER"
  signed_rpm "$OPENEULER" rsa2048
  real_rpm "$OPENEULER" tree "https://repo.openeuler.org/openEuler-24.03-LTS/everything/x86_64/Packages/tree-2.1.1-1.oe2403.x86_64.rpm"
else
  echo "NOTE: $OPENEULER could not be pulled, using rockylinux:9 as the RPM-family substitute"
  run_rpm rockylinux:9
  repo_rpm rockylinux:9
  signed_rpm rockylinux:9 rsa2048
  real_rpm rockylinux:9 tree
fi

printf '\nAll container checks passed.\n'
