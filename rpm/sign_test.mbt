///|
let signed_at : Int64 = 1800000000L

///|
fn key_of(armored : String) -> @sign.SigningKey raise {
  @sign.SigningKey::from_armored(armored)
}

///|
fn ring_of(armored : String) -> @sign.PublicKeyring raise {
  @sign.PublicKeyring::from_armored(armored)
}

///|
fn hex_of(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(bytes)
}

///|
test "sign adds tag 268 for RSA and tag 267 for Ed25519, nothing else changes" {
  let plain = @rpm.build(sample_spec())
  let before = open_rpm(plain)
  for case in [(fx_rsa_secret, 268), (fx_ed_secret, 267)] {
    let signed = @rpm.sign(plain, key_of(case.0), created=signed_at)
    let after = open_rpm(signed)
    assert_eq(after.header_bytes, before.header_bytes)
    assert_eq(after.payload, before.payload)
    assert_eq(after.lead, before.lead)
    assert_true(
      match after.signature.get(case.1) {
        Some(Bin(packet)) => packet.length() > 40
        _ => false
      },
    )
    // The size, digest and payload size tags are kept.
    for tag in [1000, 273, 1007] {
      assert_eq(after.signature.get(tag), before.signature.get(tag))
    }
    // Sorted tags, 8-byte aligned main header: the file reads back.
    let pkg = @rpm.read(signed)
    assert_eq(pkg.verify(), [])
    assert_eq(pkg.files().length(), 5)
  }
}

///|
test "signature status: unsigned, signed, good, bad" {
  let plain = @rpm.build(sample_spec())
  let rsa = key_of(fx_rsa_secret)
  let signed = @rpm.sign(plain, rsa, created=signed_at)
  let ring = ring_of(fx_rsa_public + "\n" + fx_ed_public)
  assert_eq(@rpm.read(plain).signature_status(None), Unsigned)
  assert_eq(@rpm.read(plain).signature_status(Some(ring)), Unsigned)
  assert_eq(
    @rpm.read(signed).signature_status(None),
    Signed(key_id="03D2E4B8FA9AC68F"),
  )
  match @rpm.read(signed).signature_status(Some(ring)) {
    Good(verified) => {
      assert_eq(verified.fingerprint, rsa.fingerprint())
      assert_eq(verified.created, signed_at)
    }
    _ => fail("expected a good signature")
  }
  // A keyring without the signing key.
  match @rpm.read(signed).signature_status(Some(ring_of(fx_ed_public))) {
    Bad(message) => assert_true(message.contains("unknown key"))
    _ => fail("expected a bad signature")
  }
  // A changed main header no longer matches the signature.
  let pkg = @rpm.read(signed)
  let header = pkg.header_bytes.to_array()
  header[header.length() - 1] = header[header.length() - 1] ^ 1
  let damaged : @rpm.RpmPackage = {
    ..pkg,
    header_bytes: Bytes::from_array(header),
  }
  match damaged.signature_status(Some(ring)) {
    Bad(message) => assert_true(message.contains("does not match"))
    _ => fail("expected a bad signature")
  }
  // The payload is not covered by the signature (its digest is in the header).
  let other_payload : @rpm.RpmPackage = { ..pkg, payload: b"changed", }
  assert_true(other_payload.signature_status(Some(ring)) is Good(_))
  assert_true(other_payload.verify().length() > 0)
}

///|
test "signing again replaces the earlier signature" {
  let plain = @rpm.build(sample_spec())
  let by_rsa = @rpm.sign(plain, key_of(fx_rsa_secret), created=signed_at)
  let by_ed = @rpm.sign(by_rsa, key_of(fx_ed_secret), created=signed_at)
  let signature = open_rpm(by_ed).signature
  assert_true(signature.get(268) is None)
  assert_true(signature.get(267) is Some(_))
  // Signing a signed package gives what signing the plain one gives.
  assert_eq(by_ed, @rpm.sign(plain, key_of(fx_ed_secret), created=signed_at))
}

///|
test "signing is reproducible and the time never precedes the key" {
  let plain = @rpm.build(sample_spec())
  let key = key_of(fx_rsa_secret)
  assert_eq(
    @rpm.sign(plain, key, created=signed_at),
    @rpm.sign(plain, key, created=signed_at),
  )
  assert_true(
    @rpm.sign(plain, key, created=signed_at) !=
    @rpm.sign(plain, key, created=signed_at + 1L),
  )
  let early = @rpm.sign(plain, key, created=0L)
  match @rpm.read(early).signature_status(Some(ring_of(fx_rsa_public))) {
    Good(verified) => assert_eq(verified.created, key.created())
    _ => fail("expected a good signature")
  }
}

///|
test "golden: the signed package is the same on every backend" {
  let plain = @rpm.build(sample_spec())
  assert_eq(
    hex_of(Bytes::from_iter(@crypto.sha256(plain).iter())),
    "0bde9d99b7c0b8145cf8bce1ac8bf12665a4382a918fd71e58029f1f5fa0b358",
  )
  let rsa = @rpm.sign(plain, key_of(fx_rsa_secret), created=signed_at)
  assert_eq(
    hex_of(Bytes::from_iter(@crypto.sha256(rsa).iter())),
    "3498fce4513c37fc7ae566365bfe68eb46f764b2cde5c396e59dc54174f8ef9d",
  )
  let ed = @rpm.sign(plain, key_of(fx_ed_secret), created=signed_at)
  assert_eq(
    hex_of(Bytes::from_iter(@crypto.sha256(ed).iter())),
    "80632be6e9ad01448f6b854a39a9e3728959205f899229afc2bc55450171083a",
  )
}

///|
test "sign refuses what is not an rpm" {
  let key = key_of(fx_ed_secret)
  assert_true(
    try @rpm.sign(b"nope", key, created=0L) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  assert_true(
    try @rpm.sign(@rpm.build(sample_spec())[0:200], key, created=0L) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
}
