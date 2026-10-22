# nFPM test data

Taken from [goreleaser/nfpm](https://github.com/goreleaser/nfpm) v2.48.0 (`testdata/`), MIT License (see `LICENSE`, Copyright (c) 2018 GoReleaser).

* `configs/`: the acceptance configurations `testdata/acceptance/*.yaml`, **unchanged**. Left out: the formats linuxpkg does not
  build (`ipk.*`, `msix.*`), source rpms (`srpm.*`) and the ones that need signing keys (`*sign*`).
* `tree/testdata/`: the files these configurations install, run from `testdata/nfpm/tree` (nFPM looks for sources relative to the
  current directory): `fake`, `whatever.conf`, `whatever2.conf`, `something/`, `copyright`, `changelog.yaml`, `elf32`, `elf64`,
  `acceptance/folder/`, `acceptance/scripts/`. Unchanged.

They are used by `tools/nfpm/check.sh`, which builds every configuration with the real nFPM and with linuxpkg and compares the
packages, see [docs/nfpm.md](../../docs/nfpm.md).
