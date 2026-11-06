/* A dynamically linked program without the C library's start files: _start is ours, so the
   executable holds only this code, the dynamic linking tables the linker writes, and calls into
   libc.so.6 (write, _exit) that are resolved at run time. Written for the ELF reader tests of
   linuxpkg (Apache-2.0). */
#include <unistd.h>

static const char message[] = "hello from linuxpkg\n";

void _start(void) {
  _exit(write(1, message, sizeof message - 1) < 0 ? 1 : 0);
}
