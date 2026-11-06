#!/usr/bin/env python3
"""Checks that every distributed file carries its notices: each .tar.gz has THIRD_PARTY_NOTICES and
LICENSE next to the program, each package (deb, rpm, Arch, apk) installs
/usr/share/doc/<name>/THIRD_PARTY_NOTICES, and, when the programs are statically linked with glibc,
the glibc source named in the notices is in the source directory.

usage: check_dist.py <linuxpkg binary> <directory with the files> [<glibc source directory>]
"""
import glob
import json
import os
import re
import subprocess
import sys
import tarfile

binary, directory = sys.argv[1], sys.argv[2]
sources = sys.argv[3] if len(sys.argv) > 3 else None
problems = []
checked = 0
for path in sorted(glob.glob(os.path.join(directory, "*"))):
    name = os.path.basename(path)
    if name.endswith(".tar.gz") and not name.startswith("glibc_"):
        with tarfile.open(path) as archive:
            members = {os.path.basename(m.name) for m in archive.getmembers()}
            notices = [m for m in archive.getmembers() if os.path.basename(m.name) == "THIRD_PARTY_NOTICES"]
            text = archive.extractfile(notices[0]).read().decode() if notices else ""
        for needed in ("THIRD_PARTY_NOTICES", "LICENSE"):
            if needed not in members:
                problems.append("%s: no %s" % (name, needed))
    elif name.endswith((".deb", ".rpm", ".apk", ".pkg.tar.zst", ".pkg.tar.xz")):
        report = json.loads(subprocess.run([binary, "inspect", path, "--json"], capture_output=True, text=True, check=True).stdout)
        paths = [f.get("path", "") for f in report.get("files", [])]
        wanted = "/usr/share/doc/%s/THIRD_PARTY_NOTICES" % report.get("name", "")
        if wanted not in paths:
            problems.append("%s: does not install %s" % (name, wanted))
        text = ""
    else:
        continue
    checked += 1
    if sources and text:
        match = re.search(r"GNU C Library (\S+) \(the Ubuntu package version\)", text)
        if not match:
            problems.append("%s: the notices do not name the glibc version" % name)
        elif not os.path.exists(os.path.join(sources, "glibc_%s.dsc" % match.group(1))):
            problems.append("%s: glibc_%s.dsc is not in %s" % (name, match.group(1), sources))
if checked == 0:
    problems.append("nothing to check in " + directory)
for problem in problems:
    print("problem: " + problem)
print("checked %d files, %d problems" % (checked, len(problems)))
sys.exit(1 if problems else 0)
