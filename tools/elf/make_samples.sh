#!/bin/sh
# Compiles testdata/elf/hello.c (dynamic, linked against libc.so.6) and tiny.c (static, no libc) for
# the architectures linuxpkg knows, with the Ubuntu cross compilers:
#   sudo apt-get install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-s390x-linux-gnu \
#     gcc-powerpc64le-linux-gnu gcc-i686-linux-gnu gcc-arm-linux-gnueabihf gcc-arm-linux-gnueabi \
#     gcc-mips64el-linux-gnuabi64
# Both are linked with -nostdlib: no start files (crt1.o, crti.o, crtbegin.o ...) and no libgcc go in,
# so the samples contain only code from this repository. hello is linked against the shared libc
# (-lc), which records NEEDED libc.so.6 and the program interpreter without copying any libc code.
# The script checks that by listing the symbols of each program before stripping it.
# Output goes to the directory given as the first argument (default testdata/elf/out).
set -eu
out="${1:-testdata/elf/out}"
src="$(dirname "$0")/../../testdata/elf"
mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Symbols that only start files or libgcc would bring in.
forbidden='^(_init|_fini|frame_dummy|register_tm_clones|deregister_tm_clones|__do_global_dtors_aux|__libc_csu_init|__libc_csu_fini|__libc_start_main|_dl_relocate_static_pie|__gmon_start__)$'
check() {
  defined="$("${prefix}nm" --defined-only "$1" | awk '{print $NF}')"
  if printf '%s\n' "$defined" | grep -E "$forbidden"; then
    echo "$1 contains start-file or libgcc symbols" >&2
    exit 1
  fi
  undefined="$("${prefix}nm" -u "$1" | awk '{print $NF}' | sed 's/@.*//' | sort -u | tr '\n' ' ')"
  echo "  $(basename "$1"): calls into shared libraries: ${undefined:-none}"
}
while read -r arch cc extra; do
  command -v "$cc" >/dev/null 2>&1 || { echo "skip $arch: no $cc"; continue; }
  prefix="${cc%gcc}"
  # shellcheck disable=SC2086
  "$cc" -O2 -fno-stack-protector -nostdlib -Wl,--build-id=none -Wl,-e,_start -Wl,-z,max-page-size=4096 -Wl,-z,noseparate-code $extra -o "$tmp/hello.$arch" "$src/hello.c" -lc
  # shellcheck disable=SC2086
  "$cc" -O2 -static -nostdlib -Wl,--build-id=none -Wl,-e,_start -Wl,-z,max-page-size=4096 -Wl,-z,noseparate-code $extra -o "$tmp/tiny.$arch" "$src/tiny.c"
  check "$tmp/hello.$arch"
  check "$tmp/tiny.$arch"
  "${prefix}strip" -o "$out/hello.$arch" "$tmp/hello.$arch"
  "${prefix}strip" -o "$out/tiny.$arch" "$tmp/tiny.$arch"
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
