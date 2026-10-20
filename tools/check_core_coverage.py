"""Enforce the line-coverage floor for the core packages."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
PACKAGES = (
    "Xpeng/linuxpkg/spec",
    "Xpeng/linuxpkg/archive/tar",
    "Xpeng/linuxpkg/archive/ar",
    "Xpeng/linuxpkg/archive/cpio",
    "Xpeng/linuxpkg/deb",
    "Xpeng/linuxpkg/rpm",
    "Xpeng/linuxpkg/compress",
    "Xpeng/linuxpkg/repo",
    "Xpeng/linuxpkg/arch",
    "Xpeng/linuxpkg/apk",
)
TOTAL = re.compile(r"^Total:\s+(\d+)/(\d+)\s*$", re.MULTILINE)


def run(*command: str) -> str:
    result = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"{' '.join(command)} failed with {result.returncode}")
    return result.stdout


def parse_total(output: str) -> tuple[int, int]:
    matches = TOTAL.findall(output)
    if len(matches) != 1:
        raise ValueError(f"expected one coverage total, found {len(matches)}:\n{output}")
    covered, measurable = map(int, matches[0])
    if measurable == 0 or covered > measurable:
        raise ValueError(f"invalid coverage total: {covered}/{measurable}")
    return covered, measurable


def verify(minimum: int) -> None:
    if not 0 <= minimum <= 100:
        raise ValueError("minimum coverage must be between 0 and 100")
    print("Running instrumented MoonBit tests...", flush=True)
    run("moon", "coverage", "analyze", "--", "-f", "summary")
    covered = measurable = 0
    for package in PACKAGES:
        package_covered, package_measurable = parse_total(
            run("moon", "coverage", "report", "-f", "summary", "-p", package)
        )
        covered += package_covered
        measurable += package_measurable
        print(
            f"{package}: {package_covered}/{package_measurable} "
            f"({package_covered / package_measurable:.1%})"
        )
    percent = 100 * covered / measurable
    print(f"Core line coverage: {covered}/{measurable} ({percent:.2f}%)")
    if 100 * covered < minimum * measurable:
        raise RuntimeError(f"core line coverage is below the {minimum}% floor")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minimum", type=int, default=80)
    args = parser.parse_args()
    try:
        verify(args.minimum)
    except (RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
