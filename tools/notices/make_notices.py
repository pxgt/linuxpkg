#!/usr/bin/env python3
"""Writes THIRD_PARTY_NOTICES: the third-party software compiled or linked into a MoonBit program,
with the notices and license texts that must go with every binary copy.

usage:
  make_notices.py --project linuxpkg --version 0.5.1 --module-root . --kind js -o OUT
  make_notices.py --project linuxpkg --version 0.5.1 --module-root . --kind native \
      [--glibc-tarball glibc_2.35.orig.tar.xz --glibc-version 2.35-0ubuntu3.13 \
       --source-place "the GitHub release v0.5.1 of linuxpkg" --source-tag v0.5.1] -o OUT

--kind js      the JavaScript build (the web page): MoonBit core and the modules of moon.mod.
--kind native  a native program: also the MoonBit C runtime and simdutf from the toolchain.
               With --glibc-tarball the program is taken to be statically linked: glibc
               (LGPL-2.1-or-later, its COPYING.LIB and LICENSES are read from the tarball) and libgcc
               (GPL-3.0-or-later WITH GCC-exception-3.1, read from the Debian/Ubuntu copyright file
               of GCC) are added, with where their source is and how to relink the program.

The MoonBit modules are the imports of <module-root>/moon.mod, read from <module-root>/.mooncakes
(run `moon update` first); the toolchain files come from $MOON_HOME (default ~/.moon). Anything
the script cannot find is an error: it never writes an incomplete file.
"""
import argparse
import glob
import os
import re
import sys
import tarfile

# simdutf (https://github.com/simdutf/simdutf) is under "Apache-2.0 OR MIT"; the MIT text of its
# LICENSE-MIT file is reproduced for it.
SIMDUTF_MIT = """Copyright 2021 The simdutf authors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

TEMPLATE = re.compile(r"\[yyyy\]|\[name of copyright owner\]|copyright notice|Copyright License|APPENDIX", re.I)


def fail(message):
    sys.exit("make_notices.py: " + message)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def mod_field(text, key):
    match = re.search(r'^%s\s*=\s*"([^"]*)"' % key, text, re.M)
    return match.group(1) if match else ""


def module_imports(root):
    path = os.path.join(root, "moon.mod")
    if not os.path.exists(path):
        fail("no moon.mod in " + root)
    block = re.search(r"^import\s*\{(.*?)^\}", read(path), re.S | re.M)
    if not block:
        return []
    return [name.split("@")[0] for name in re.findall(r'"([^"]+)"', block.group(1))]


LICENSE_NAME = re.compile(r"^(LICEN[CS]E|NOTICE|COPYING)([-._][\w.-]*)?$", re.I)


def is_license_file(base):
    return bool(LICENSE_NAME.match(base)) and not base.lower().endswith((".toml", ".json", ".yaml", ".yml"))


def copyright_lines(directory):
    """Copyright lines of the code that is compiled in: sources (not tests) and license files."""
    found = {}
    for path in glob.glob(os.path.join(directory, "**", "*"), recursive=True):
        base = os.path.basename(path)
        if not os.path.isfile(path):
            continue
        source = base.endswith(".mbt") and not base.endswith(("_test.mbt", "_wbtest.mbt"))
        if not (source or is_license_file(base)):
            continue
        for line in read(path).splitlines():
            if "Copyright" not in line or TEMPLATE.search(line):
                continue
            text = re.sub(r"^[\s/*#|]+", "", line).strip()
            if text.startswith("Copyright"):
                found[text] = found.get(text, 0) + 1
    return sorted(found, key=lambda t: (-found[t], t))


def extra_license_files(directory):
    """License or notice files that are not the plain Apache-2.0 text: they are reproduced."""
    extra = []
    for path in sorted(glob.glob(os.path.join(directory, "*")) + glob.glob(os.path.join(directory, "LICENSES", "*"))):
        base = os.path.basename(path)
        in_licenses = os.path.basename(os.path.dirname(path)) == "LICENSES"
        if not os.path.isfile(path) or not (is_license_file(base) or in_licenses):
            continue
        text = read(path)
        if "Apache License" in text and "Version 2.0, January 2004" in text and base.upper().startswith("LICENSE"):
            continue
        extra.append((os.path.relpath(path, directory).replace(os.sep, "/"), text))
    return extra


def gcc_exception():
    for path in sorted(glob.glob("/usr/share/doc/gcc-*-base/copyright"), reverse=True):
        text = read(path)
        start = text.find("GCC RUNTIME LIBRARY EXCEPTION")
        end_marker = "requirements of the license of GCC."
        end = text.find(end_marker, start)
        if start >= 0 and end > start:
            return text[start:end + len(end_marker)] + "\n", path
    fail("the GCC Runtime Library Exception was not found in /usr/share/doc/gcc-*-base/copyright")


def common_license(name):
    path = "/usr/share/common-licenses/" + name
    if not os.path.exists(path):
        fail(path + " is missing (install base-files)")
    return read(path)


def tar_member(tarball, suffix):
    with tarfile.open(tarball) as archive:
        for member in archive.getmembers():
            if member.isfile() and member.name.count("/") == 1 and member.name.endswith("/" + suffix):
                return archive.extractfile(member).read().decode("utf-8", "replace")
    fail("%s has no top-level %s" % (tarball, suffix))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--module-root", default=".")
    parser.add_argument("--kind", choices=["native", "js"], required=True)
    parser.add_argument("--glibc-tarball")
    parser.add_argument("--glibc-version")
    parser.add_argument("--source-place", default="")
    parser.add_argument("--source-tag", default="")
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args()
    static = args.glibc_tarball is not None
    if static and args.kind != "native":
        fail("--glibc-tarball only makes sense with --kind native")
    if static and not (args.glibc_version and args.source_place and args.source_tag):
        fail("--glibc-tarball needs --glibc-version, --source-place and --source-tag")
    moon_home = os.environ.get("MOON_HOME", os.path.expanduser("~/.moon"))
    core = os.path.join(moon_home, "lib", "core")
    for needed in ("LICENSE", "NOTICE"):
        if not os.path.exists(os.path.join(core, needed)):
            fail("%s/%s is missing" % (core, needed))
    root = os.path.abspath(args.module_root)
    what = "JavaScript file" if args.kind == "js" else "program"

    out = []
    w = out.append
    w("THIRD-PARTY NOTICES")
    w("===================")
    w("")
    w("%s %s, %s build" % (args.project, args.version, "JavaScript (web page)" if args.kind == "js" else
                           ("native, statically linked" if static else "native")))
    w("")
    w("%s itself is licensed under the Apache License 2.0 (its LICENSE file). This file lists the" % args.project)
    w("third-party software that is compiled or linked into this %s, with the copyright notices," % what)
    w("notices and license texts that go with every copy of it.")
    w("")
    sections = ["MoonBit modules", "MoonBit core library"]
    if args.kind == "native":
        sections += ["MoonBit C runtime", "simdutf"]
    if static:
        sections += ["GNU C Library (glibc), statically linked", "libgcc (GCC runtime library)"]
    sections.append("License texts")
    w("Contents:")
    for number, title in enumerate(sections, 1):
        w("  %d. %s" % (number, title))
    w("")

    def heading(title):
        line = "%d. %s" % (sections.index(title) + 1, title)
        w("")
        w(line)
        w("-" * len(line))
        w("")

    heading("MoonBit modules")
    w("These MoonBit modules (https://mooncakes.io) are compiled into the %s. Unless said otherwise" % what)
    w("below, each is licensed under the Apache License 2.0, whose text is in section %d." % len(sections))
    w("")
    for name in module_imports(root):
        directory = os.path.join(root, ".mooncakes", *name.split("/"))
        mod_path = os.path.join(directory, "moon.mod")
        if not os.path.exists(mod_path):
            fail("module %s not found in %s/.mooncakes (run moon update)" % (name, root))
        mod = read(mod_path)
        license_id = mod_field(mod, "license") or "unknown"
        repository = mod_field(mod, "repository")
        w("* %s %s (%s)%s" % (name, mod_field(mod, "version"), license_id, (" " + repository) if repository else ""))
        lines = copyright_lines(directory)
        if lines:
            for line in lines[:6]:
                w("    " + line)
        else:
            w("    Copyright the %s authors" % name.split("/")[0])
        for relative, text in extra_license_files(directory):
            w("    It also carries %s, reproduced here:" % relative)
            w("")
            for line in text.rstrip().splitlines():
                w("      " + line if line else "")
            w("")
    heading("MoonBit core library")
    w("The MoonBit standard library (moonbitlang/core), from the MoonBit toolchain, is compiled into the")
    w("%s. It is licensed under the Apache License 2.0. Its NOTICE file, which the license" % what)
    w("requires to be passed on, is reproduced here:")
    w("")
    for line in read(os.path.join(core, "NOTICE")).rstrip().splitlines():
        w("    " + line if line else "")
    if args.kind == "native":
        heading("MoonBit C runtime")
        w("The C runtime of the MoonBit toolchain (moonbit.h, runtime.c and the files next to it) is")
        w("linked into the program. Copyright International Digital Economy Academy; Apache License 2.0.")
        heading("simdutf")
        w("The toolchain's UTF-8 and UTF-16 routines come from simdutf (https://github.com/simdutf/simdutf),")
        w("licensed under the Apache License 2.0 or the MIT license. Its MIT license notice:")
        w("")
        for line in SIMDUTF_MIT.rstrip().splitlines():
            w("    " + line if line else "")
    if static:
        tag_url = "https://github.com/pxgt/%s/tree/%s" % (args.project, args.source_tag)
        heading("GNU C Library (glibc), statically linked")
        w("This program is statically linked with the GNU C Library %s (the Ubuntu package version)," % args.glibc_version)
        w("which is licensed under the GNU Lesser General Public License, version 2.1 or (at your option)")
        w("any later version. Some of its parts are under the other licenses listed in its LICENSES file,")
        w("reproduced below. The LGPL text is in section %d." % len(sections))
        w("")
        w("Source of the library: the Ubuntu source package of this exact version (the .dsc file, the")
        w(".orig.tar.xz and the .debian.tar.xz), published at the same place as this program:")
        w("%s." % args.source_place)
        w("")
        w("Relinking: the complete source of %s is at %s (Apache-2.0)." % (args.project, tag_url))
        w("To link it against a modified glibc, install the modified static library (libc.a) and its")
        w("headers, then, in a checkout of that tag:")
        w("")
        w("    printf '\\noptions(\\n  link: { \"native\": { \"cc-link-flags\": \"-static\" } },\\n)\\n' >> cmd/main/moon.pkg")
        w("    moon update && moon build --target native --release cmd/main")
        w("")
        w("The program is _build/native/release/build/cmd/main/main.exe.")
        w("")
        w("The LICENSES file of glibc:")
        w("")
        for line in tar_member(args.glibc_tarball, "LICENSES").rstrip().splitlines():
            w("    " + line if line else "")
        heading("libgcc (GCC runtime library)")
        exception, where = gcc_exception()
        w("Parts of libgcc, the runtime library of GCC, are linked into the program. libgcc is licensed")
        w("under the GNU General Public License version 3 or later with the GCC Runtime Library Exception")
        w("3.1, which allows the program to be distributed under its own license. The exception (from")
        w("%s):" % where)
        w("")
        for line in exception.rstrip().splitlines():
            w("    " + line if line else "")

    heading("License texts")
    w("Apache License 2.0")
    w("~~~~~~~~~~~~~~~~~~")
    w("")
    w(read(os.path.join(core, "LICENSE")).rstrip())
    if static:
        w("")
        w("GNU Lesser General Public License, version 2.1 (COPYING.LIB of glibc)")
        w("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        w("")
        w(tar_member(args.glibc_tarball, "COPYING.LIB").rstrip())
        w("")
        w("GNU General Public License, version 3 (for libgcc, with the exception above)")
        w("~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")
        w("")
        w(common_license("GPL-3").rstrip())
    w("")
    with open(args.output, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out))
    print("wrote %s (%d lines)" % (args.output, len(out)))


main()
