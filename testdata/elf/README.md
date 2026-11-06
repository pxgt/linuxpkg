# ELF samples

Made by `tools/elf/make_samples.sh` with the Ubuntu 22.04 cross compilers from the two programs next to this
file. They are linked with `-nostdlib`: no start files of the C library (`crt1.o`, `crti.o`, `crtn.o`), no
`crtbegin.o` / `crtend.o` and no libgcc go in, and the script checks the symbols of every program before it
strips it. So the samples contain only the code of `hello.c` and `tiny.c` (Apache-2.0) and the tables the
linker writes.

* `hello.<arch>`: `hello.c`, dynamic, stripped. `_start` is ours; the program is linked against the shared C
  library (`-lc`), which only records `NEEDED libc.so.6` and the program interpreter: `write` and `_exit` are
  found in it at run time, nothing of it is copied into the file.
* `tiny.<arch>`: `tiny.c`, static, no libc, stripped (a few hundred bytes).

`<arch>` is the package architecture: amd64, arm64, i386, armhf, armel, ppc64le, s390x, riscv64, mips64le. LoongArch has no cross
compiler in Ubuntu 22.04, so it is only covered by hand-made headers in `elf/elf_test.mbt`.

`elf/samples_test.mbt` holds these files as base64 together with what `readelf` says about them
(`tools/elf/samples_to_mbt.py` regenerates it). The programs are not meant to be run.
