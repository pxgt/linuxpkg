name = "Xpeng/linuxpkg"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/pxgt/linuxpkg"

license = "Apache-2.0"

keywords = [ "deb", "rpm", "packaging", "linux", "archive" ]

preferred_target = "wasm-gc"

description = "Pure-MoonBit toolkit to build, inspect and verify Linux deb and rpm packages, without dpkg-deb or rpmbuild"

import {
  "moonbit-community/flate@0.9.0",
  "moonbitlang/x@0.5.5",
}
