# ELF samples

Made by `tools/elf/make_samples.sh` with the Ubuntu 22.04 cross compilers (gcc 11) from the two programs next to this file; no
third-party binary is included.

* `hello.<arch>`: `hello.c`, dynamic, stripped (needs libc and the dynamic linker of that architecture).
* `tiny.<arch>`: `tiny.c`, static, no libc, stripped (a few hundred bytes).

`<arch>` is the package architecture: amd64, arm64, i386, armhf, armel, ppc64le, s390x, riscv64, mips64le. LoongArch has no cross
compiler in Ubuntu 22.04, so it is only covered by hand-made headers in `elf/elf_test.mbt`.

`elf/samples_test.mbt` holds these files as base64 together with what `readelf` says about them
(`tools/elf/samples_to_mbt.py` regenerates it). The programs are not meant to be run.
