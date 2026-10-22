name = "Xpeng/linuxpkg"

version = "0.5.0"

readme = "README.md"

repository = "https://github.com/pxgt/linuxpkg"

license = "Apache-2.0"

keywords = [ "deb", "rpm", "packaging", "linux", "archive", "apk", "pacman" ]

preferred_target = "wasm-gc"

description = "Pure-MoonBit toolkit to build, inspect and verify Linux packages (deb, rpm, Arch, Alpine) and apt/dnf repositories, without dpkg-deb or rpmbuild"

import {
  "moonbit-community/flate@0.9.0",
  "moonbitlang/x@0.5.5",
  "Milky2018/zstd@0.1.4",
  "aurora0x27/lzma-mbt@0.1.0",
  "lin2077-zeming/moonxz@0.4.4",
  "justinwongcn/moonpgp@0.1.0",
  "moonbitstack/moonyaml@0.1.1",
}
