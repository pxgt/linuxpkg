///|
let signed_at : Int64 = 1800000000L

///|
fn rsa() -> @sign.SigningKey raise {
  @sign.SigningKey::from_armored(fx_rsa_secret)
}

///|
fn alpine_key() -> @sign.PublicKeyring raise {
  @sign.PublicKeyring::from_pem(rsa().rsa_public_pem())
}

///|
test "a signed package keeps its control and data streams" {
  let plain = @apk.build(sample_spec())
  let signed = @apk.sign(
    plain,
    rsa(),
    key_name="mykey.rsa.pub",
    created=signed_at,
  )
  let before = @apk.read(plain)
  let after = @apk.read(signed)
  assert_eq(before.signatures, [])
  assert_eq(after.signatures, [".SIGN.RSA256.mykey.rsa.pub"])
  assert_eq(after.control_packed, before.control_packed)
  assert_eq(after.data_packed, before.data_packed)
  assert_eq(after.pkginfo, before.pkginfo)
  assert_eq(after.verify(), [])
  // The signature stream is a tar without end marker holding one file.
  assert_eq(after.signature_files.length(), 1)
  assert_eq(after.signature_files[0].1.length(), 256)
  assert_eq(after.signature_files[0].2, signed_at)
  // Signing is reproducible, and the same for every call.
  assert_eq(
    signed,
    @apk.sign(plain, rsa(), key_name="mykey.rsa.pub", created=signed_at),
  )
  // Signing a signed package replaces the signature.
  assert_eq(
    @apk.sign(signed, rsa(), key_name="mykey.rsa.pub", created=signed_at),
    signed,
  )
  assert_eq(@apk.read(signed).to_json().stringify().contains("RSA256"), true)
}

///|
test "signature status: unsigned, signed, good, bad, SHA-1" {
  let plain = @apk.build(sample_spec())
  let key = rsa()
  let signed = @apk.sign(
    plain,
    key,
    key_name="mykey.rsa.pub",
    created=signed_at,
  )
  let ring = alpine_key()
  assert_eq(@apk.read(plain).signature_status(None), @sign.Unsigned)
  assert_eq(@apk.read(plain).signature_status(Some(ring)), @sign.Unsigned)
  assert_eq(
    @apk.read(signed).signature_status(None),
    @sign.Signed(key_id="mykey.rsa.pub"),
  )
  match @apk.read(signed).signature_status(Some(ring)) {
    @sign.Good(verified) => {
      assert_eq(verified.key_id, "mykey.rsa.pub")
      assert_eq(verified.created, signed_at)
    }
    _ => fail("expected a good signature")
  }
  // The OpenPGP public key of the same RSA key works as a keyring too.
  assert_true(
    @apk.read(signed).signature_status(
      Some(@sign.PublicKeyring::from_armored(fx_rsa_public)),
    )
    is @sign.Good(_),
  )
  // SHA-1 signatures (`.SIGN.RSA.`, what abuild writes) are read too.
  let sha1 = @apk.sign(
    plain,
    key,
    key_name="old.rsa.pub",
    created=signed_at,
    hash=Sha1,
  )
  assert_eq(@apk.read(sha1).signatures, [".SIGN.RSA.old.rsa.pub"])
  assert_true(@apk.read(sha1).signature_status(Some(ring)) is @sign.Good(_))
  // A key that did not sign it.
  let other = @sign.PublicKeyring::from_armored(fx_ed_public)
  assert_true(@apk.read(signed).signature_status(Some(other)) is @sign.Bad(_))
  // The control stream changed after signing: its signature no longer matches.
  let pkg = @apk.read(signed)
  let control = pkg.control_packed.to_array()
  control[control.length() - 9] = control[control.length() - 9] ^ 1
  let damaged : @apk.ApkPackage = {
    ..pkg,
    control_packed: Bytes::from_array(control),
  }
  assert_true(damaged.signature_status(Some(ring)) is @sign.Bad(_))
  // A signature of a kind we do not know (DSA) is reported, not accepted.
  let dsa : @apk.ApkPackage = {
    ..pkg,
    signature_files: [(".SIGN.DSA.x.pub", b"abc", 0L)],
  }
  assert_eq(
    dsa.signature_status(None),
    @sign.Bad(".SIGN.DSA.x.pub: only RSA signatures are supported"),
  )
  assert_true(dsa.signature_status(Some(ring)) is @sign.Bad(_))
}

///|
test "signing refuses bad key names and non-packages" {
  let plain = @apk.build(sample_spec())
  for name in ["", "a/b.rsa.pub", "x".repeat(81)] {
    assert_true(
      try @apk.sign(plain, rsa(), key_name=name, created=0L) catch {
        @apk.ApkError::Invalid(field~, ..) => field == "key name"
        _ => false
      } noraise {
        _ => false
      },
    )
  }
  assert_true(
    try @apk.sign(b"nope", rsa(), key_name="k.rsa.pub", created=0L) catch {
      _ => true
    } noraise {
      _ => false
    },
  )
  // An Ed25519 key cannot make an Alpine signature.
  let ed = @sign.SigningKey::from_armored(fx_ed_secret)
  assert_true(
    try @apk.sign(plain, ed, key_name="k.rsa.pub", created=0L) catch {
      @apk.ApkError::Invalid(field="signature", ..) => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "sign_index puts the signature in front of the whole index" {
  let index = @compress.compress(b"C:Q1abc\nP:hello\n\n", Gzip)
  let signed = @apk.sign_index(
    index[:],
    rsa(),
    key_name="mykey.rsa.pub",
    created=signed_at,
  )
  let stream = @apk.signature_stream(
    index[:],
    rsa(),
    key_name="mykey.rsa.pub",
    created=signed_at,
  )
  assert_eq(signed, Bytes::from_array([..stream, ..index]))
  // The stream is itself a gzip stream; the index follows unchanged.
  let members = @compress.gzip_members(signed[:], max_size=1000000)
  assert_eq(members.length(), 2)
  assert_eq(members[1].0, index)
}

///|
test "golden: signed package is the same on every backend" {
  let plain = @apk.build(sample_spec())
  let signed = @apk.sign(
    plain,
    rsa(),
    key_name="mykey.rsa.pub",
    created=signed_at,
  )
  assert_eq(
    @crypto.bytes_to_hex_string(@crypto.sha256(signed)),
    "f9deee2f8471f507dfe8ba2d9384c46bd1bdb60a6f156f65d5ee9d2f2a7aaf97",
  )
}
