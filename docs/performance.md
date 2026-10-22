# Performance

Measured with `tools/bench.sh` (release builds of `cmd/main`), one run per cell, on a Windows 11 desktop in WSL2 (Ubuntu 22.04).
The numbers show orders of magnitude, not a benchmark suite; run the script on your own machine for yours.
The input tree is a multiple of 10 MB files, half text-like data and half random bytes (the random half does not compress).
`wasm-gc` is `moonrun` on the release wasm-gc build.

## gzip (the default), four formats

| Input | Backend | deb | rpm | Arch | Alpine |
|---|---|---|---|---|---|
| 50 MB | native | 0.7 s · 210 MB | 1.1 s · 210 MB | 0.9 s · 211 MB | 1.1 s · 202 MB |
| 50 MB | wasm-gc | 17.5 s · 416 MB | 14.7 s · 404 MB | 17.2 s · 413 MB | 15.3 s · 412 MB |
| 200 MB | native | 3.2 s · 771 MB | 4.5 s · 771 MB | 4.0 s · 774 MB | 4.4 s · 770 MB |
| 200 MB | wasm-gc | 61 s · 1267 MB | 62 s · 1252 MB | 62 s · 1032 MB | 63 s · 1361 MB |

(time · peak memory)

## For comparison (same 50 MB and 200 MB trees, gzip)

| | 50 MB | 200 MB | size of the 50 MB result |
|---|---|---|---|
| linuxpkg deb, native | 0.7 s | 3.2 s | 25,275,460 bytes |
| `dpkg-deb -Zgzip --build` | 4.9 s | 17.0 s | 24,313,502 bytes |
| `tar \| gzip -6` | 1.1 s | 4.2 s | 24,604,788 bytes |

linuxpkg writes the gzip stream about 7 times faster than `dpkg-deb` here and about 4 % larger: the deflate implementation in
`moonbit-community/flate` stores incompressible blocks quickly and does not search as hard as `gzip -9`. A comparison with
nFPM was not made (it is not installed here).

## xz and zstd (50 MB, deb)

| | native | wasm-gc |
|---|---|---|
| xz (level 9) | 91 s · 340 MB | 119 s · 543 MB |
| zstd (level 9) | 145 s · 555 MB | 269 s · 959 MB |

The same cost applies to the other formats (xz measured for rpm and Arch too: 81–101 s native). These two encoders are the slow
part of linuxpkg: about 0.5 MB/s for xz and 0.3 MB/s for zstd, and the zstd output is much larger than the official tool's (see
[formats.md](formats.md)). **gzip stays the default for that reason**; use xz or zstd when the target distribution asks for it
or the package is small.

## What to expect

* Time grows linearly with the input; gzip builds run at roughly 60 MB/s on native and 3–4 MB/s on wasm-gc.
* Memory is about four times the input on native and six times on wasm-gc: the files, the archive and the compressed stream are
  all held in memory (a design choice that keeps the core free of file system code). Packages of a few hundred megabytes are
  fine on a developer machine or CI runner; for multi-gigabyte inputs use the native backend and plenty of memory.
* In a browser tab the same code runs as JavaScript; the page is meant for packages of megabytes, not gigabytes.
* No hot spot was optimised for this release: the profile is dominated by the compression libraries, which are not ours.
