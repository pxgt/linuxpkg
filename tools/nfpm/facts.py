#!/usr/bin/env python3
"""Read the facts of a package with the official tools (dpkg-deb, rpm, tar) as JSON.

usage: facts.py PACKAGE

What is reported is what two independent writers of the same configuration should agree on:
the metadata, the relations, the files (mode, owner, link target) and the scripts. Times, sizes,
checksums and compression are left out on purpose.
"""
import json
import os
import re
import subprocess
import sys
import tempfile


def run(*cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=True, **kw).stdout


def deb_facts(path):
    fields = {}
    current = None
    for line in run("dpkg-deb", "-f", path).split("\n"):
        if line.startswith((" ", "\t")) and current:
            fields[current] += "\n" + line.strip()
        elif ":" in line:
            current, value = line.split(":", 1)
            fields[current] = value.strip()
    for volatile in ("Installed-Size",):
        fields.pop(volatile, None)
    files = []
    for line in run("dpkg-deb", "-c", path).split("\n"):
        m = re.match(r"^(\S+)\s+(\S+)\s+\d+\s+\S+\s+\S+\s+(.*)$", line)
        if not m:
            continue
        mode, owner, rest = m.groups()
        target = ""
        if " -> " in rest:
            rest, target = rest.split(" -> ", 1)
        rest = rest.lstrip(".")
        if rest == "/":
            continue
        files.append(f"{mode} {owner} {rest}{' -> ' + target if target else ''}")
    scripts = {}
    conffiles = []
    with tempfile.TemporaryDirectory() as d:
        run("dpkg-deb", "-e", path, d)
        for name in sorted(os.listdir(d)):
            full = os.path.join(d, name)
            if name == "conffiles":
                conffiles = sorted(open(full).read().split())
            elif name in ("preinst", "postinst", "prerm", "postrm"):
                scripts[name] = open(full, errors="replace").read()
    return {
        "format": "deb",
        "fields": fields,
        "files": sorted(files),
        "conffiles": conffiles,
        "scripts": scripts,
    }


def rpm_facts(path):
    qf = lambda f: run("rpm", "-qp", "--nosignature", "--qf", f, path)
    info = {}
    for key in ("NAME", "VERSION", "RELEASE", "EPOCH", "ARCH", "SUMMARY", "DESCRIPTION", "VENDOR", "URL", "LICENSE", "PACKAGER", "GROUP"):
        info[key.lower()] = qf("%{" + key + "}").strip()
    relations = {}
    for flag in ("requires", "provides", "conflicts", "obsoletes", "recommends", "suggests"):
        try:
            lines = run("rpm", "-qp", "--nosignature", "--" + flag, path).split("\n")
        except subprocess.CalledProcessError:
            lines = []
        relations[flag] = sorted(l.strip() for l in lines if l.strip() and not l.startswith("rpmlib(") and l.strip() != "(none)")
    files = []
    for line in qf("[%{FILEMODES:perms} %{FILEUSERNAME}/%{FILEGROUPNAME} %{FILENAMES} %{FILELINKTOS} %{FILEFLAGS:fflags}\\n]").split("\n"):
        parts = line.split(" ")
        if len(parts) >= 3:
            link = parts[3] if len(parts) > 3 else ""
            flags = parts[4] if len(parts) > 4 else ""
            files.append(f"{parts[0]} {parts[1]} {parts[2]}{' -> ' + link if link else ''} [{flags}]")
    scripts = run("rpm", "-qp", "--nosignature", "--scripts", path)
    return {
        "format": "rpm",
        "info": info,
        "relations": relations,
        "files": sorted(files),
        "scripts": scripts,
    }


def tar_facts(path, kind):
    with tempfile.TemporaryDirectory() as d:
        if kind == "arch":
            run("tar", "--zstd", "-xf", path, "-C", d)
            listing = run("tar", "--zstd", "-tvf", path)
        else:
            run("tar", "--ignore-zeros", "-xzf", path, "-C", d)
            listing = run("tar", "--ignore-zeros", "-tzvf", path)
        pkginfo = {}
        multi = {}
        for line in open(os.path.join(d, ".PKGINFO"), errors="replace").read().split("\n"):
            if line.startswith("#") or "=" not in line:
                continue
            key, value = [x.strip() for x in line.split("=", 1)]
            if key in ("builddate", "size", "datahash"):
                continue
            multi.setdefault(key, []).append(value)
        for key, values in multi.items():
            pkginfo[key] = sorted(values) if key in ("depend", "provides", "conflict", "replaces", "license", "optdepend") else values
        files = []
        for line in listing.split("\n"):
            m = re.match(r"^(\S+)\s+(\S+)\s+\d+\s+\S+\s+\S+\s+(.*)$", line)
            if not m:
                continue
            mode, owner, rest = m.groups()
            # Metadata files of the package format (.PKGINFO, .MTREE, scripts, signatures).
            if rest.startswith(".") and not rest.startswith("./"):
                continue
            if owner in ("0/0", "root/root"):
                owner = "root/root"
            target = ""
            if " -> " in rest:
                rest, target = rest.split(" -> ", 1)
            if rest.startswith("./"):
                rest = rest[1:]
            if not rest.startswith("/"):
                rest = "/" + rest
            if rest == "/":
                continue
            rest = rest.rstrip("/") + ("/" if mode.startswith("d") else "")
            files.append(f"{mode} {owner} {rest}{' -> ' + target if target else ''}")
        scripts = {}
        for name in (".INSTALL", ".post-install", ".pre-install", ".pre-deinstall", ".post-deinstall", ".post-upgrade", ".pre-upgrade"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                scripts[name] = open(p, errors="replace").read()
    return {"format": kind, "pkginfo": pkginfo, "files": sorted(files), "scripts": scripts}


def main():
    path = sys.argv[1]
    if path.endswith(".deb"):
        facts = deb_facts(path)
    elif path.endswith(".rpm"):
        facts = rpm_facts(path)
    elif path.endswith(".apk"):
        facts = tar_facts(path, "apk")
    elif ".pkg.tar" in path:
        facts = tar_facts(path, "arch")
    else:
        sys.exit("unknown package type: " + path)
    json.dump(facts, sys.stdout, indent=2, sort_keys=True)
    print()


main()
