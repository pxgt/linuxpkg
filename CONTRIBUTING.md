# Contributing

Thanks for helping. A few rules keep `main` always green.

## Workflow

1. Open an issue describing the change.
2. Create a branch, make focused commits (each one a complete small change with its tests), open a pull request.
3. CI must be green before the merge: formatting, interface files, `moon check --deny-warn`, tests on
   wasm-gc, wasm, js and native, the oracle checks against `dpkg`/`rpm`, and the container installs.
4. Merge with a merge commit. Do not force-push or rewrite history.

## Before you push

```sh
moon fmt
moon info                      # commit the changed pkg.generated.mbti files
moon check --target all --deny-warn
moon test --target wasm-gc     # and js, wasm; native on Linux or WSL
python tools/check_core_coverage.py --minimum 80
```

On Linux or WSL also run `tools/oracle/run.sh` (see `docs/verification.md`).

## Code conventions

- The core packages (`spec`, `archive/*`, `deb`, `rpm`) must stay portable: no file system access. Only
  `cmd/main` reads and writes files.
- Output must depend only on the input: no clocks, random numbers or map iteration order in output.
- Readers must return a typed error for any input and never crash; bound everything an input can make large.
- Error messages name the offending field or byte offset.
- Derived `Eq`/`Debug` on public types need the compatibility `extend` declarations in the package's
  `deprecated.mbt` (see the existing ones).
- Shell scripts are committed with the executable bit and LF line endings.

## Changing a format

Verify with the real tool first (dpkg, rpm, GNU tar/cpio) and record any difference from the specification in
`docs/formats.md`. Add the official tool's output as a fixture when practical.

## License

By contributing you agree that your contribution is licensed under Apache-2.0.
