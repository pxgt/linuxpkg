#!/bin/bash
# Regenerates testdata/sign/ and sign/fixtures_test.mbt: throw-away OpenPGP keys
# (RSA-2048, Ed25519 and a passphrase-protected one) made by gpg, plus the
# signatures gpg itself produces over a fixed text, which the tests verify.
# The keys are for tests only. They are public on purpose and worthless.
# Usage: tools/oracle/make_sign_fixtures.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/testdata/sign"
mkdir -p "$OUT"
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"' EXIT
GPG="gpg --batch --yes --pinentry-mode loopback"

gen() { # name, key block lines..., passphrase ('' for none)
  local name="$1" pass="$2"; shift 2
  {
    printf '%s\n' "$@"
    if [ -z "$pass" ]; then echo "%no-protection"; else echo "Passphrase: $pass"; fi
    echo "Name-Real: linuxpkg test-only $name"
    echo "Name-Email: test-only-$name@example.invalid"
    echo "Expire-Date: 0"
    echo "%commit"
  } > "$GNUPGHOME/$name.params"
  $GPG --gen-key "$GNUPGHOME/$name.params" 2>&1 | tail -3
}

gen rsa2048 "" "Key-Type: RSA" "Key-Length: 2048" "Key-Usage: sign"
gen ed25519 "" "Key-Type: EDDSA" "Key-Curve: ed25519" "Key-Usage: sign"
gen locked "secret" "Key-Type: RSA" "Key-Length: 2048" "Key-Usage: sign"

printf 'linuxpkg signing test data\nsecond line  \n- starts with a dash\n' > "$OUT/data.txt"

for name in rsa2048 ed25519 locked; do
  fpr=$(gpg --batch --list-keys --with-colons "test-only-$name@example.invalid" | awk -F: '/^fpr/ {print $10; exit}')
  if [ "$name" = locked ]; then pass=secret; else pass=""; fi
  $GPG --passphrase "$pass" --armor --export-secret-keys "$fpr" > "$OUT/test-only-$name.sec.asc"
  gpg --batch --armor --export "$fpr" > "$OUT/test-only-$name.pub.asc"
  echo "$name $fpr" >> "$OUT/fingerprints.txt.new"
  if [ "$name" != locked ]; then
    $GPG --local-user "$fpr" --armor --detach-sign --digest-algo SHA256 -o "$OUT/gpg-$name.sig.asc" "$OUT/data.txt"
    $GPG --local-user "$fpr" --detach-sign --digest-algo SHA256 -o "$OUT/gpg-$name.sig" "$OUT/data.txt"
    $GPG --local-user "$fpr" --clearsign --digest-algo SHA256 -o "$OUT/gpg-$name.clearsigned.asc" "$OUT/data.txt"
  fi
done
sort "$OUT/fingerprints.txt.new" > "$OUT/fingerprints.txt"
rm "$OUT/fingerprints.txt.new"

cat > "$OUT/README.md" <<'EOF'
# Test-only keys

Everything in this directory is for the unit tests and the oracle script of linuxpkg.
The private keys are **public on purpose and worthless**: never trust a signature made with them.
They were made by `tools/oracle/make_sign_fixtures.sh` with gpg.

- `test-only-rsa2048`, `test-only-ed25519`: unprotected keys (`*.sec.asc` private, `*.pub.asc` public).
- `test-only-locked`: RSA key protected by the passphrase `secret`, to test the "locked key" error.
- `gpg-*.sig`, `gpg-*.sig.asc`, `gpg-*.clearsigned.asc`: what gpg signs for `data.txt`, so that we can verify
  signatures made by the reference implementation.
EOF

python3 "$ROOT/tools/oracle/sign_fixtures_to_mbt.py" "$ROOT"
echo "fixtures written to $OUT and sign/fixtures_test.mbt"
cat "$OUT/fingerprints.txt"
