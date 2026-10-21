# Test-only keys

Everything in this directory is for the unit tests and the oracle script of linuxpkg.
The private keys are **public on purpose and worthless**: never trust a signature made with them.
They were made by `tools/oracle/make_sign_fixtures.sh` with gpg.

- `test-only-rsa2048`, `test-only-ed25519`: unprotected keys (`*.sec.asc` private, `*.pub.asc` public).
- `test-only-locked`: RSA key protected by the passphrase `secret`, to test the "locked key" error.
- `gpg-*.sig`, `gpg-*.sig.asc`, `gpg-*.clearsigned.asc`: what gpg signs for `data.txt`, so that we can verify
  signatures made by the reference implementation.
