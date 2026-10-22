#!/bin/sh
# Compiles testdata/elf/hello.c (dynamic, needs libc) and tiny.c (static, no libc) for the
# architectures linuxpkg knows, with the Ubuntu cross compilers:
#   sudo apt-get install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-s390x-linux-gnu \
#     gcc-powerpc64le-linux-gnu gcc-i686-linux-gnu gcc-arm-linux-gnueabihf gcc-arm-linux-gnueabi \
#     gcc-mips64el-linux-gnuabi64
# Output goes to the directory given as the first argument (default testdata/elf/out).
set -eu
out="${1:-testdata/elf/out}"
src="$(dirname "$0")/../../testdata/elf"
mkdir -p "$out"
while read -r arch cc extra; do
  command -v "$cc" >/dev/null 2>&1 || { echo "skip $arch: no $cc"; continue; }
  # shellcheck disable=SC2086
  "$cc" -O2 -s -Wl,-z,max-page-size=4096 -Wl,-z,noseparate-code $extra -o "$out/hello.$arch" "$src/hello.c"
  # shellcheck disable=SC2086
  "$cc" -O2 -s -static -nostdlib -Wl,--build-id=none -Wl,-e,_start -Wl,-z,max-page-size=4096 -Wl,-z,noseparate-code $extra -o "$out/tiny.$arch" "$src/tiny.c"
  echo "made $arch"
done <<'LIST'
amd64 x86_64-linux-gnu-gcc
arm64 aarch64-linux-gnu-gcc
i386 i686-linux-gnu-gcc
armhf arm-linux-gnueabihf-gcc
armel arm-linux-gnueabi-gcc
ppc64le powerpc64le-linux-gnu-gcc
s390x s390x-linux-gnu-gcc
riscv64 riscv64-linux-gnu-gcc
mips64le mips64el-linux-gnuabi64-gcc
LIST
