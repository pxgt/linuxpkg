#!/bin/bash
# Regenerates rpm/fixtures_test.mbt with rpms written by the real rpmbuild:
# one with a gzip payload and, for the "unsupported compression" tests, ones
# with xz and zstd payloads (zstd only if this rpm can write it).
# Usage: tools/oracle/make_rpm_fixtures.sh [output-file]
set -e
OUT="${1:-rpm/fixtures_test.mbt}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
W=$(mktemp -d)
cd "$W"
mkdir -p top/BUILD top/RPMS top/SPECS
cat > top/SPECS/realrpm.spec <<'EOF'
Name: realrpm
Version: 2.5
Release: 3
Summary: A package built by rpmbuild
License: MIT
URL: https://example.org/realrpm
BuildArch: noarch
Requires: bash >= 4.0
Provides: realthing = 1
Conflicts: oldthing < 2
AutoReqProv: no

%description
Second line of the description.

%install
mkdir -p %{buildroot}/usr/share/realrpm %{buildroot}/etc
printf 'hello from rpmbuild\n' > %{buildroot}/usr/share/realrpm/data.txt
printf 'setting=1\n' > %{buildroot}/etc/realrpm.conf
ln -s data.txt %{buildroot}/usr/share/realrpm/link
chmod 644 %{buildroot}/usr/share/realrpm/data.txt %{buildroot}/etc/realrpm.conf

%files
%config(noreplace) /etc/realrpm.conf
%dir /usr/share/realrpm
/usr/share/realrpm/data.txt
/usr/share/realrpm/link

%post
echo installed > /dev/null
EOF
export SOURCE_DATE_EPOCH=1700000000
build() { # payload-macro output-name
  rpmbuild -bb --define "_topdir $W/top" --define "_binary_payload $1" \
    --define "_build_id_links none" --define "use_source_date_epoch_as_buildtime 1" \
    --define "clamp_mtime_to_source_date_epoch 1" --define "_buildhost localhost" \
    top/SPECS/realrpm.spec >/dev/null 2>&1
  mv top/RPMS/noarch/realrpm-2.5-3.noarch.rpm "$2"
}
build w9.gzdio real_gzip.rpm
build w2.xzdio real_xz.rpm
HAVE_ZSTD=0
if build w19.zstdio real_zstd.rpm 2>/dev/null && [ -f real_zstd.rpm ]; then HAVE_ZSTD=1; fi
RPM_VERSION=$(rpm --version)
python3 - "$OUT" "$RPM_VERSION" "$HAVE_ZSTD" <<'PY'
import sys, binascii
out = []
out.append('///|')
out.append('/// RPMs written by the real rpmbuild (%s) with' % sys.argv[2])
out.append('/// `SOURCE_DATE_EPOCH=1700000000 rpmbuild -bb` and the payload macros')
out.append('/// w9.gzdio, w2.xzdio and w19.zstdio. Regenerate them with')
out.append('/// tools/oracle/make_rpm_fixtures.sh.')
names = [('real_gzip_rpm', 'real_gzip.rpm'), ('real_xz_rpm', 'real_xz.rpm')]
if sys.argv[3] == '1':
    names.append(('real_zstd_rpm', 'real_zstd.rpm'))
for name, path in names:
    hexed = binascii.hexlify(open(path, 'rb').read()).decode()
    out.append('')
    out.append('///|')
    out.append('let %s : String =' % name)
    for i in range(0, len(hexed), 96):
        out.append('  #|' + hexed[i:i + 96])
open(sys.argv[1], 'w', newline='\n').write('\n'.join(out) + '\n')
PY
echo "wrote $OUT (zstd: $HAVE_ZSTD)"
rpm -qip real_gzip.rpm
rpm -qlvp real_gzip.rpm
rpm -qp --requires --provides --conflicts real_gzip.rpm
rpm -qp --qf '[%{FILENAMES} %{FILEFLAGS} %{FILESIZES} %{FILEDIGESTS}\n]' real_gzip.rpm
rpm -qp --qf 'payload=%{PAYLOADCOMPRESSOR} algo=%{FILEDIGESTALGO}\n' real_gzip.rpm real_xz.rpm
ls -l real_*.rpm
rpm -Kv real_gzip.rpm
rm -rf "$W"
