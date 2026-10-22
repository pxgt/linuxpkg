#!/usr/bin/env python3
"""Compare `linuxpkg elf --json` with `readelf -h -l -d` for the given files.

usage: compare_readelf.py LINUXPKG FILE...

A file called NAME.ARCH (for example hello.arm64, made by tools/elf/make_samples.sh) must also
give ARCH as the package architecture. Exit status 1 on any difference.
"""
import json
import re
import subprocess
import sys

CLASS = {"ELF32": 32, "ELF64": 64}


def readelf(path):
    def run(flag):
        return subprocess.run(
            ["readelf", flag, "-W", path], capture_output=True, text=True, check=True
        ).stdout

    header, program, dynamic = run("-h"), run("-l"), run("-d")
    cls = re.search(r"Class:\s+(\w+)", header).group(1)
    data = re.search(r"Data:\s+(.*)", header).group(1)
    interp = re.search(r"Requesting program interpreter: (.*?)\]", program)
    return {
        "bits": CLASS[cls],
        "little": "little endian" in data,
        "interpreter": interp.group(1) if interp else None,
        "needed": re.findall(r"\(NEEDED\)\s+Shared library: \[(.*?)\]", dynamic),
        "soname": (re.findall(r"\(SONAME\)\s+Library soname: \[(.*?)\]", dynamic) or [None])[0],
        "type": re.search(r"Type:\s+(\w+)", header).group(1),
    }


def main():
    tool, files = sys.argv[1], sys.argv[2:]
    bad = 0
    for path in files:
        if path.endswith(".c"):
            continue
        ours = json.loads(
            subprocess.run([tool, "elf", "--json", path], capture_output=True, text=True, check=True).stdout
        )
        theirs = readelf(path)
        problems = []
        if ours["bits"] != theirs["bits"]:
            problems.append(f"bits {ours['bits']} != {theirs['bits']}")
        if (ours["byte_order"] == "little") != theirs["little"]:
            problems.append("byte order differs")
        if ours["interpreter"] != theirs["interpreter"]:
            problems.append(f"interpreter {ours['interpreter']} != {theirs['interpreter']}")
        if ours["needed"] != theirs["needed"]:
            problems.append(f"needed {ours['needed']} != {theirs['needed']}")
        if ours["soname"] != theirs["soname"]:
            problems.append(f"soname {ours['soname']} != {theirs['soname']}")
        want_type = {"EXEC": "executable", "DYN": "shared object or PIE", "REL": "relocatable"}.get(theirs["type"])
        if want_type and ours["type"] != want_type:
            problems.append(f"type {ours['type']} != {want_type}")
        suffix = path.rsplit(".", 1)[-1]
        if suffix in ("amd64", "arm64", "i386", "armhf", "armel", "ppc64le", "s390x", "riscv64", "mips64le"):
            if ours["arch"] != suffix:
                problems.append(f"arch {ours['arch']} != {suffix}")
        status = "ok" if not problems else "DIFFERENT: " + "; ".join(problems)
        print(f"{path}: {ours['arch']} {ours['bits']}-bit {ours['linkage']} {status}")
        bad += bool(problems)
    sys.exit(1 if bad else 0)


main()
