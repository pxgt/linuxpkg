#!/bin/bash
# Regenerates deb/fixtures_test.mbt with debs written by the real dpkg-deb:
# one with gzip members and one with xz members (which linuxpkg must report
# as unsupported). Usage: tools/oracle/make_deb_fixtures.sh [output-file]
set -e
OUT="${1:-deb/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
mkdir -p pkg/DEBIAN pkg/usr/share/realdeb pkg/etc
cat > pkg/DEBIAN/control <<'EOF'
Package: realdeb
Version: 2.5-3
Architecture: all
Maintainer: Real Deb <real@example.org>
Installed-Size: 1
Depends: bash (>= 4.0), coreutils
Section: misc
Priority: optional
Homepage: https://example.org/realdeb
Description: A package built by dpkg-deb
 Second line of the description.
 .
 After a blank line.
EOF
printf 'hello from dpkg-deb\n' > pkg/usr/share/realdeb/data.txt
printf 'setting=1\n' > pkg/etc/realdeb.conf
ln -s data.txt pkg/usr/share/realdeb/link
printf '/etc/realdeb.conf\n' > pkg/DEBIAN/conffiles
printf '#!/bin/sh\nexit 0\n' > pkg/DEBIAN/postinst
chmod 755 pkg/DEBIAN/postinst
chmod 644 pkg/usr/share/realdeb/data.txt pkg/etc/realdeb.conf
(cd pkg && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums)
find pkg -exec chmod g-w {} +
find pkg -exec touch -h -d @1700000000 {} +
export SOURCE_DATE_EPOCH=1700000000
dpkg-deb --root-owner-group -Zgzip --build pkg real_gzip.deb >/dev/null
dpkg-deb --root-owner-group -Zxz --build pkg real_xz.deb >/dev/null
DPKG_VERSION=$(dpkg-deb --version | head -n 1)
python3 - "$OUT" "$DPKG_VERSION" <<'PY'
import sys, binascii
out = []
out.append('///|')
out.append('/// Debs written by the real dpkg-deb (%s) with' % sys.argv[2])
out.append('/// `SOURCE_DATE_EPOCH=1700000000 dpkg-deb --root-owner-group -Z<gzip|xz> --build`.')
out.append('/// Regenerate them with tools/oracle/make_deb_fixtures.sh.')
for name, path in (('real_gzip_deb', 'real_gzip.deb'), ('real_xz_deb', 'real_xz.deb')):
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
dpkg-deb --info real_gzip.deb | head -20
dpkg-deb --contents real_gzip.deb
ls -l real_gzip.deb real_xz.deb
rm -rf "$W"
