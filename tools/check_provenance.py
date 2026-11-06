#!/usr/bin/env python3
"""Fails when the repository holds binary data whose origin is not recorded in testdata/PROVENANCE.md.

It looks at the files git tracks and finds
  * binary files (a NUL byte in the first 8 KiB),
  * MoonBit constants made of hex or base64 lines (`let name : String =` followed by `#|` lines)
    of more than 1 KiB of text,
  * MoonBit string literals of more than 1 KiB of base64 or hex.
Each binary file must be named in PROVENANCE.md by its path or by a directory that contains it
(written with a trailing slash); each constant by `file` and `name`; each file with long literals
by its path. The check also fails on PROVENANCE.md entries that no longer match anything.

usage: tools/check_provenance.py [--list]
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIMIT = 1024
DATA_LINE = re.compile(r"^\s*#\|([0-9A-Za-z+/= ]+)\s*$")
LET = re.compile(r"^(?:pub\s+)?let\s+(\w+)\s*(?::\s*\w+)?\s*=\s*$")
LITERAL = re.compile(r'"([0-9A-Za-z+/=]{%d,})"' % LIMIT)


def tracked():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


def is_binary(path):
    with open(os.path.join(ROOT, path), "rb") as handle:
        return b"\0" in handle.read(8192)


def findings():
    found = []
    for path in tracked():
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            continue
        if is_binary(path):
            found.append(("binary", path, None))
            continue
        if not path.endswith(".mbt"):
            continue
        lines = open(full, encoding="utf-8", errors="replace").read().splitlines()
        name, size = None, 0
        for line in lines + [""]:
            data = DATA_LINE.match(line)
            if data and name:
                size += len(data.group(1).replace(" ", ""))
                continue
            if name and size > LIMIT:
                found.append(("constant", path, name))
            name, size = None, 0
            let = LET.match(line)
            if let:
                name = let.group(1)
        if any(LITERAL.search(line) for line in lines):
            found.append(("literal", path, None))
    return found


def main():
    items = findings()
    if "--list" in sys.argv:
        for kind, path, name in items:
            print(kind, path, name or "")
        return
    text = open(os.path.join(ROOT, "testdata", "PROVENANCE.md"), encoding="utf-8").read()
    cells = re.findall(r"`([^`]+)`", text)
    paths = {c for c in cells if "/" in c or "." in c}
    names = set(cells)
    problems = []
    for kind, path, name in items:
        covering = [p for p in paths if p == path or (p.endswith("/") and path.startswith(p))]
        if not covering:
            problems.append("%s %s is not in testdata/PROVENANCE.md" % (kind, path))
            continue
        if kind == "constant" and name not in names:
            problems.append("constant %s in %s is not in testdata/PROVENANCE.md" % (name, path))
    files = set(tracked())
    listed = re.findall(r"^\|\s*`([^`]+)`", text, re.M)
    for entry in listed:
        exists = entry in files or (entry.endswith("/") and any(f.startswith(entry) for f in files))
        if not exists:
            problems.append("testdata/PROVENANCE.md lists %s, which is not in the repository" % entry)
    for problem in problems:
        print("problem: " + problem)
    print("%d data items checked, %d problems" % (len(items), len(problems)))
    sys.exit(1 if problems else 0)


main()
