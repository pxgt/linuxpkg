#!/usr/bin/env python3
"""Build every nFPM configuration of a directory with nFPM and with linuxpkg and compare the packages.

usage: compare.py NFPM LINUXPKG CONFIGS_DIR TREE_DIR [--formats deb,rpm,apk,arch] [--config NAME]...
                  [--expect FILE] [--json]

The sources of the configurations are the files below TREE_DIR; both tools run in a copy of it with
the same environment (BUILD_ARCH=amd64, SEMVER=v1.2.3-beta, SOURCE_DATE_EPOCH=1700000000).
The packages are read back with the official tools (facts.py) and compared field by field. nFPM and
linuxpkg are independent implementations, so byte equality is not expected; what has to match is
what a package manager shows. Differences that are known and explained (docs/nfpm.md) are listed in
the --expect file as `config format key`; the exit status is 1 for any other difference and for
expected ones that no longer happen.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FORMATS = {"deb": ("deb", ".deb"), "rpm": ("rpm", ".rpm"), "apk": ("apk", ".apk"), "arch": ("archlinux", ".pkg.tar.zst")}


def run(cmd, cwd, env):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def facts(path):
    out = subprocess.run([sys.executable, os.path.join(HERE, "facts.py"), path], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[-300:])
    return json.loads(out.stdout)


def pick(directory, suffix):
    names = [n for n in os.listdir(directory) if n.endswith(suffix)]
    return os.path.join(directory, names[0]) if names else None


def normalize(f, fmt):
    """Drop what is not a difference of substance (see docs/nfpm.md)."""
    f = json.loads(json.dumps(f))
    # The root directory is listed by one tool and not by the other.
    f["files"] = [x for x in f["files"] if not x.split(" ")[2] in ("/", "./")]
    f.pop("scripts", None)  # compared separately, by name
    return f


def flatten(value, prefix=""):
    items = {}
    if isinstance(value, dict):
        for k, v in value.items():
            items.update(flatten(v, f"{prefix}{k}."))
    else:
        items[prefix.rstrip(".")] = value
    return items


def file_map(entries):
    """path -> entry, for entries like `-rw-r--r-- root/root /usr/bin/x -> target [flags]`."""
    result = {}
    for entry in entries:
        parts = entry.split(" ")
        result[parts[2]] = entry
    return result


def diff_keys(a, b):
    """Keys where the two fact dictionaries differ; the files are compared one by one (`files[/path]`)."""
    keys = []
    fa, fb = flatten(a), flatten(b)
    for k in sorted(set(fa) | set(fb)):
        va, vb = fa.get(k, "<absent>"), fb.get(k, "<absent>")
        if va == vb:
            continue
        if k == "files" and isinstance(va, list) and isinstance(vb, list):
            ma, mb = file_map(va), file_map(vb)
            for path in sorted(set(ma) | set(mb)):
                if ma.get(path) != mb.get(path):
                    keys.append(f"files[{path}]")
        else:
            keys.append(k)
    return keys


def main():
    args = sys.argv[1:]
    if len(args) < 4:
        sys.exit(__doc__)
    nfpm, linuxpkg, configs, tree = [os.path.abspath(a) for a in args[:4]]
    formats = ["deb", "rpm", "apk", "arch"]
    only = []
    expect_file = None
    as_json = False
    show = False
    i = 4
    while i < len(args):
        if args[i] == "--formats":
            formats = args[i + 1].split(",")
            i += 2
        elif args[i] == "--config":
            only.append(args[i + 1])
            i += 2
        elif args[i] == "--expect":
            expect_file = args[i + 1]
            i += 2
        elif args[i] == "--json":
            as_json = True
            i += 1
        elif args[i] == "--show":
            show = True
            i += 1
        else:
            sys.exit("unknown option " + args[i])
    expected = set()
    if expect_file:
        for line in open(expect_file):
            line = line.split("#")[0].strip()
            if line:
                expected.add(tuple(line.split(None, 2)))
    work = tempfile.mkdtemp()
    root = os.path.join(work, "tree")
    shutil.copytree(tree, root)
    for dirpath, dirs, files in os.walk(root):
        for name in files:
            os.chmod(os.path.join(dirpath, name), 0o644)
        for name in dirs:
            os.chmod(os.path.join(dirpath, name), 0o755)
    env = dict(os.environ, BUILD_ARCH="amd64", SEMVER="v1.2.3-beta", SOURCE_DATE_EPOCH="1700000000", NFPM_PASSPHRASE="")
    results = []
    seen = set()
    for name in sorted(os.listdir(configs)):
        if not name.endswith(".yaml") or (only and name[:-5] not in only):
            continue
        config = os.path.join(configs, name)
        for fmt in formats:
            packager, suffix = FORMATS[fmt]
            tag = name[:-5]
            out_n, out_l = os.path.join(work, "n", tag, fmt), os.path.join(work, "l", tag, fmt)
            os.makedirs(out_n)
            os.makedirs(out_l)
            n = run([nfpm, "package", "-f", config, "-p", packager, "-t", out_n], root, env)
            l = run([linuxpkg, "build", config, "--format", fmt, "--out", out_l], root, env)
            pn, pl = pick(out_n, suffix), pick(out_l, suffix)
            if n.returncode != 0 or pn is None:
                status = "nfpm-failed" if (l.returncode != 0 or pl is None) else "nfpm-failed-ours-built"
                results.append((tag, fmt, status, [], (n.stderr or n.stdout).strip().split("\n")[-1][:120]))
                continue
            if l.returncode != 0 or pl is None:
                msg = [x for x in l.stderr.strip().split("\n") if not x.startswith("linuxpkg: warning")]
                results.append((tag, fmt, "ours-failed", [], (msg[-1] if msg else "")[:160]))
                continue
            try:
                a, b = normalize(facts(pn), fmt), normalize(facts(pl), fmt)
            except RuntimeError as e:
                results.append((tag, fmt, "facts-failed", [], str(e)[:120]))
                continue
            keys = diff_keys(a, b)
            detail = []
            fa, fb = flatten(a), flatten(b)
            ma, mb = file_map(fa.get("files", [])), file_map(fb.get("files", []))
            for k in keys:
                if k.startswith("files["):
                    path = k[6:-1]
                    detail.append(f"{k}: nfpm={ma.get(path)!r} linuxpkg={mb.get(path)!r}")
                    continue
                va, vb = fa.get(k, "<absent>"), fb.get(k, "<absent>")
                if isinstance(va, list) and isinstance(vb, list):
                    detail.append(f"{k}: only nfpm {[x for x in va if x not in vb]} only linuxpkg {[x for x in vb if x not in va]}")
                else:
                    detail.append(f"{k}: nfpm={va!r} linuxpkg={vb!r}")
            results.append((tag, fmt, "same" if not keys else "different", keys, ("\n    ").join(detail)))
    bad = 0
    for tag, fmt, status, keys, detail in results:
        if status not in ("same", "different"):
            # One tool could not build it: that has to be a known case as well.
            keys = [status]
            status_key = status
            ok = (tag, fmt, status_key) in expected
            seen.add((tag, fmt, status_key))
            if not ok:
                bad += 1
                print(f"UNEXPECTED {tag} {fmt} {status_key}")
        if status == "different":
            for key in keys:
                ok = (tag, fmt, key) in expected or (tag, fmt, "*") in expected or ("*", fmt, key) in expected
                seen.add((tag, fmt, key))
                seen.add(("*", fmt, key))
                seen.add((tag, fmt, "*"))
                if not ok:
                    bad += 1
                    print(f"UNEXPECTED {tag} {fmt} {key}")
        if as_json:
            print(json.dumps([tag, fmt, status, keys, detail]))
        else:
            print(f"{tag:34} {fmt:5} {status:24} {' '.join(keys)[:150]}")
            if show and status != "same" and detail:
                print("    " + detail)
    stale = sorted(e for e in expected if e not in seen and e[1] in formats and (not only or e[0] in only))
    for e in stale:
        print("STALE expectation:", " ".join(e))
    shutil.rmtree(work, ignore_errors=True)
    counts = {}
    for r in results:
        counts[r[2]] = counts.get(r[2], 0) + 1
    print("summary:", counts, "unexpected differences:", bad, "stale expectations:", len(stale))
    sys.exit(1 if bad or stale else 0)


main()
