# Self-hosting example

linuxpkg packages its own native command line program:

```sh
moon build --target native --release cmd/main
moon run cmd/main --target native -- build examples/self/linuxpkg.json --out dist
sudo dpkg -i dist/linuxpkg_*_amd64.deb && linuxpkg --version
```

`version` in `linuxpkg.json` must match `VERSION` in `version.mbt`; `tools/oracle/run.sh`
checks that. The binary is read from `_build`, so build it first.
