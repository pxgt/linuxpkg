#!/usr/bin/env bash
# Prepares what must go with a statically linked MoonBit program built on Ubuntu: the source of the
# exact glibc that was linked in, and the THIRD_PARTY_NOTICES file (tools/notices/make_notices.py).
#
# Usage: tools/notices/prepare_dist.sh <project> <version> <module-root> <git-ref> <source-dir> <notices-file> <source-place>
#   <git-ref>       tag or commit of <project> that the program was built from (for the relinking note)
#   <source-dir>    where the files of the glibc source package are written
#   <source-place>  where these source files will be published, in words, for the notices
# The glibc version is the one of the libc6-dev package of this machine. Its source package is
# downloaded from Launchpad, which keeps every published version: first the .dsc, then every file it
# lists, each checked against the SHA-256 and size the .dsc gives.
set -euo pipefail
PROJECT="$1"
VERSION="$2"
MODULE_ROOT="$3"
REF="$4"
SRC_DIR="$5"
NOTICES="$6"
PLACE="$7"
HERE="$(cd "$(dirname "$0")" && pwd)"

GLIBC="$(dpkg-query -W -f='${Version}' libc6-dev)"
UPSTREAM="${GLIBC%%-*}"
mkdir -p "$SRC_DIR"
python3 - "$GLIBC" "$SRC_DIR" <<'PY'
import hashlib, os, re, subprocess, sys
version, directory = sys.argv[1:3]
base = "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/glibc/" + version + "/"

def fetch(name):
    # A broken connection resumes the partial file (-C -) instead of starting again.
    path = os.path.join(directory, name)
    for attempt in range(3):
        done = subprocess.run(["curl", "-fsSL", "--retry", "5", "--retry-all-errors", "-C", "-",
                               "-o", path + ".part", base + name]).returncode == 0
        if done:
            os.replace(path + ".part", path)
            return
    sys.exit("could not download " + base + name)

def good(name, digest, size):
    path = os.path.join(directory, name)
    if not os.path.exists(path) or os.path.getsize(path) != size:
        return False
    return hashlib.sha256(open(path, "rb").read()).hexdigest() == digest

dsc = "glibc_%s.dsc" % version
if not os.path.exists(os.path.join(directory, dsc)):
    fetch(dsc)
block = re.search(r"^Checksums-Sha256:\n((?: .+\n)+)", open(os.path.join(directory, dsc)).read(), re.M)
if not block:
    sys.exit("%s has no Checksums-Sha256 field" % dsc)
for line in block.group(1).splitlines():
    digest, size, name = line.split()
    if not good(name, digest, int(size)):
        fetch(name)
    if not good(name, digest, int(size)):
        sys.exit("glibc source file %s does not match %s" % (name, dsc))
    print("glibc source %s: matches %s" % (name, dsc))
PY
python3 "$HERE/make_notices.py" --project "$PROJECT" --version "$VERSION" --module-root "$MODULE_ROOT" \
  --kind native --glibc-tarball "$SRC_DIR/glibc_$UPSTREAM.orig.tar.xz" --glibc-version "$GLIBC" \
  --source-place "$PLACE" --source-tag "$REF" -o "$NOTICES"
