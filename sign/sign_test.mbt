///|
let created : Int64 = 1700000000L

///|
fn signed_data() -> Bytes {
  @utf8.encode(fx_data + "\n")
}

///|
fn hex_to_bytes(text : String) -> Bytes {
  let digits : Array[Int32] = []
  for c in text {
    let v = c.to_int()
    if v >= 48 && v <= 57 {
      digits.push(v - 48)
    } else if v >= 97 && v <= 102 {
      digits.push(v - 87)
    }
  }
  Bytes::makei(digits.length() / 2, i => {
    (digits[2 * i] * 16 + digits[2 * i + 1]).to_byte()
  })
}

///|
fn to_hex(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(bytes)
}

///|
#warnings("-result_error_return")
fn[T] outcome(f : () -> T raise @sign.SignError) -> Result[T, @sign.SignError] {
  Ok(f()) catch {
    e => Err(e)
  }
}

///|
fn rsa_key() -> @sign.SigningKey raise @sign.SignError {
  @sign.SigningKey::from_armored(fx_rsa_secret)
}

///|
fn ed_key() -> @sign.SigningKey raise @sign.SignError {
  @sign.SigningKey::from_armored(fx_ed_secret)
}

///|
fn ring() -> @sign.PublicKeyring raise @sign.SignError {
  @sign.PublicKeyring::from_armored(fx_rsa_public + "\n" + fx_ed_public)
}

///|
test "keys: fingerprint, key id, algorithm" {
  let rsa = rsa_key()
  assert_eq(rsa.fingerprint(), "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F")
  assert_eq(rsa.key_id(), "03D2E4B8FA9AC68F")
  assert_true(rsa.is_rsa())
  assert_eq(rsa.rsa_bits(), 2048)
  let ed = ed_key()
  assert_eq(ed.fingerprint(), "66A22F1760CE2ABB10060451E2F97F5A50BD0EB3")
  assert_eq(ed.key_id(), "E2F97F5A50BD0EB3")
  assert_false(ed.is_rsa())
  assert_eq(ed.rsa_bits(), 0)
}

///|
test "keys: a binary key file reads like the armored one" {
  let armored = @armor.decode(fx_rsa_secret)
  let key = @sign.SigningKey::from_bytes(armored.data())
  assert_eq(key.fingerprint(), "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F")
}

///|
test "keys: a passphrase-protected key is refused with a clear error" {
  assert_true(
    outcome(() => @sign.SigningKey::from_armored(fx_locked_secret))
    is Err(@sign.Locked),
  )
  assert_true(
    "\{@sign.SignError::Locked}".contains("protected by a passphrase"),
  )
}

///|
test "keys: things that are not private keys" {
  assert_true(
    outcome(() => @sign.SigningKey::from_armored("")) is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.SigningKey::from_armored("hello")) is Err(@sign.Key(..)),
  )
  // A public key block is not a private key.
  assert_true(
    outcome(() => @sign.SigningKey::from_armored(fx_rsa_public))
    is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.SigningKey::from_bytes(b"")) is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.SigningKey::from_bytes(b"\x01\x02\x03\x04"))
    is Err(@sign.Key(..)),
  )
  // Cut off in the middle of the secret key packet.
  let whole = @armor.decode(fx_rsa_secret).data()
  for n in [10, 40, 100, 300, whole.length() / 2] {
    let part = whole[0:n].to_owned()
    assert_true(
      outcome(() => @sign.SigningKey::from_bytes(part)) is Err(@sign.Key(..)),
    )
  }
}

///|
test "gpg's own signatures verify: armored, binary and cleartext" {
  let ring = ring()
  let rsa = ring.verify_detached(
    signed_data()[:],
    @utf8.encode(fx_rsa_sig_armored),
  )
  assert_eq(rsa.fingerprint, "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F")
  assert_eq(rsa.key_id, "03D2E4B8FA9AC68F")
  let ed = ring.verify_detached(
    signed_data()[:],
    @utf8.encode(fx_ed_sig_armored),
  )
  assert_eq(ed.fingerprint, "66A22F1760CE2ABB10060451E2F97F5A50BD0EB3")
  let rsa_bin = ring.verify_detached(
    signed_data()[:],
    hex_to_bytes(fx_rsa_sig_hex),
  )
  assert_eq(rsa_bin, rsa)
  let ed_bin = ring.verify_detached(
    signed_data()[:],
    hex_to_bytes(fx_ed_sig_hex),
  )
  assert_eq(ed_bin, ed)
  let (text, who) = ring.verify_cleartext(fx_rsa_clearsigned + "\n")
  assert_eq(text, fx_data + "\n")
  assert_eq(who, rsa)
  let (text, who) = ring.verify_cleartext(fx_ed_clearsigned + "\n")
  assert_eq(text, fx_data + "\n")
  assert_eq(who, ed)
}

///|
test "our signatures verify: armored, binary and cleartext, both algorithms" {
  let ring = ring()
  for key in [rsa_key(), ed_key()] {
    let binary = key.detached(signed_data()[:], created~)
    let verified = ring.verify_detached(signed_data()[:], binary)
    assert_eq(verified.fingerprint, key.fingerprint())
    assert_eq(verified.key_id, key.key_id())
    assert_eq(verified.created, created)
    let armored = key.detached_armored(signed_data()[:], created~)
    assert_true(armored.has_prefix("-----BEGIN PGP SIGNATURE-----\n\n"))
    assert_true(armored.has_suffix("-----END PGP SIGNATURE-----\n"))
    assert_eq(
      ring.verify_detached(signed_data()[:], @utf8.encode(armored)),
      verified,
    )
    let clear = key.cleartext(fx_data + "\n", created~)
    assert_true(
      clear.has_prefix("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n"),
    )
    let (text, who) = ring.verify_cleartext(clear)
    assert_eq(text, fx_data + "\n")
    assert_eq(who, verified)
  }
}

///|
test "signatures are reproducible: same input, same bytes" {
  for key in [rsa_key(), ed_key()] {
    let a = key.detached(signed_data()[:], created~)
    let b = key.detached(signed_data()[:], created~)
    assert_eq(a, b)
    assert_eq(
      key.cleartext("one\ntwo\n", created~),
      key.cleartext("one\ntwo\n", created~),
    )
    // The signature time is part of the signature.
    assert_true(a != key.detached(signed_data()[:], created=created + 1L))
  }
}

///|
test "golden signatures (the same on every backend)" {
  assert_eq(
    to_hex(rsa_key().detached(signed_data()[:], created~)),
    golden_rsa_hex.replace_all(old="\n", new=""),
  )
  assert_eq(
    to_hex(ed_key().detached(signed_data()[:], created~)),
    golden_ed_hex.replace_all(old="\n", new=""),
  )
}

///|
test "the signature time must fit in 32 bits" {
  let key = rsa_key()
  assert_true(
    outcome(() => key.detached(b""[:], created=-1L)) is Err(@sign.Invalid(..)),
  )
  assert_true(
    outcome(() => key.detached(b""[:], created=4294967296L))
    is Err(@sign.Invalid(..)),
  )
  assert_true(outcome(() => key.detached(b""[:], created=4294967295L)) is Ok(_))
  assert_true(outcome(() => key.detached(b""[:], created=0L)) is Ok(_))
  let verified = ring().verify_detached(
    b""[:],
    key.detached(b""[:], created=4294967295L),
  )
  assert_eq(verified.created, 4294967295L)
}

///|
test "changed data, a foreign key and damaged signatures are refused" {
  let ring = ring()
  let key = rsa_key()
  let signature = key.detached(signed_data()[:], created~)
  let changed = signed_data().to_array()
  changed[3] = changed[3] ^ 1
  assert_true(
    outcome(() => ring.verify_detached(Bytes::from_array(changed)[:], signature))
    is Err(@sign.BadSignature(..)),
  )
  assert_true(
    outcome(() => ring.verify_detached(b""[:], signature))
    is Err(@sign.BadSignature(..)),
  )
  // Only the Ed25519 key is in this keyring.
  let ed_only = @sign.PublicKeyring::from_armored(fx_ed_public)
  match outcome(() => ed_only.verify_detached(signed_data()[:], signature)) {
    Err(@sign.BadSignature(message~)) =>
      assert_true(
        message.contains("unknown key 7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F"),
      )
    _ => fail("expected an unknown key error")
  }
  // Flip every byte of the signature in turn: an error or, for the few bytes
  // that are not covered (the unhashed issuer key id and its type byte), nothing at all.
  let bytes = signature.to_array()
  let mut accepted = 0
  for i in 0..<bytes.length() {
    let copy = bytes.copy()
    copy[i] = copy[i] ^ 0x40
    let result = outcome(() => {
      ring.verify_detached(signed_data()[:], Bytes::from_array(copy))
    })
    if result is Ok(_) {
      accepted += 1
    }
  }
  assert_true(accepted <= 9)
  // Truncations.
  for n in 0..<bytes.length() {
    let part = Bytes::from_array(bytes[0:n])
    assert_true(
      outcome(() => ring.verify_detached(signed_data()[:], part)) is Err(_),
    )
  }
  assert_true(
    outcome(() => ring.verify_detached(signed_data()[:], b""))
    is Err(@sign.Invalid(..)),
  )
}

///|
test "a flipped bit in an Ed25519 signature is refused" {
  let ring = ring()
  let signature = ed_key().detached(signed_data()[:], created~)
  let bytes = signature.to_array()
  // The last 64 bytes hold r and s.
  for i in [bytes.length() - 1, bytes.length() - 10, bytes.length() - 40] {
    let copy = bytes.copy()
    copy[i] = copy[i] ^ 1
    assert_true(
      outcome(() => {
        ring.verify_detached(signed_data()[:], Bytes::from_array(copy))
      })
      is Err(_),
    )
  }
}

///|
test "cleartext: dash escaping, line endings, trailing space, no final newline" {
  let key = rsa_key()
  let ring = ring()
  let text = "-----BEGIN PGP SIGNATURE-----\n- dash\nspaces   \r\ntab\t\nlast"
  let clear = key.cleartext(text, created~)
  assert_true(clear.contains("\n- -----BEGIN PGP SIGNATURE-----\n"))
  assert_true(clear.contains("\n- - dash\n"))
  let (back, _) = ring.verify_cleartext(clear)
  assert_eq(
    back, "-----BEGIN PGP SIGNATURE-----\n- dash\nspaces   \ntab\t\nlast\n",
  )
  // The same text with different trailing spaces has the same signature.
  assert_true(clear.contains("spaces   \n"))
  let plain = key.cleartext("a\nb\n", created~)
  let crlf = key.cleartext("a\r\nb\r\n", created~)
  assert_eq(plain, crlf)
  let nofinal = key.cleartext("a\nb", created~)
  assert_eq(plain, nofinal)
  let (empty_text, _) = ring.verify_cleartext(key.cleartext("", created~))
  assert_eq(empty_text, "")
  let (blank, _) = ring.verify_cleartext(key.cleartext("\n\nx\n\n", created~))
  assert_eq(blank, "\n\nx\n\n")
}

///|
test "cleartext: changed text, missing parts and non-messages are refused" {
  let key = rsa_key()
  let ring = ring()
  let clear = key.cleartext("Origin: test\nSHA256:\n abc 1 file\n", created~)
  assert_true(
    outcome(() => ring.verify_cleartext(clear.replace(old="abc", new="abd")))
    is Err(@sign.BadSignature(..)),
  )
  assert_true(
    outcome(() => {
      ring.verify_cleartext(
        clear.replace(old="Hash: SHA256", new="Hash: SHA512"),
      )
    })
    is Ok(_),
  )
  assert_true(
    outcome(() => ring.verify_cleartext("plain text")) is Err(@sign.Invalid(..)),
  )
  assert_true(
    outcome(() => ring.verify_cleartext("")) is Err(@sign.Invalid(..)),
  )
  let header_only = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n"
  assert_true(
    outcome(() => ring.verify_cleartext(header_only)) is Err(@sign.Invalid(..)),
  )
  let no_signature = header_only + "\ntext\n"
  assert_true(
    outcome(() => ring.verify_cleartext(no_signature)) is Err(@sign.Invalid(..)),
  )
  // Drop the signature block's body.
  let broken = header_only +
    "\ntext\n-----BEGIN PGP SIGNATURE-----\n\nAAAA\n=AAAA\n-----END PGP SIGNATURE-----\n"
  assert_true(outcome(() => ring.verify_cleartext(broken)) is Err(_))
  // A detached signature is not a cleartext signature, and the other way round.
  let detached = key.detached(b"x\n"[:], created~)
  assert_true(
    outcome(() => ring.verify_detached(b"x\n"[:], @utf8.encode(clear)))
    is Err(_),
  )
  ignore(detached)
}

///|
test "keyring: several keys, private key files, nothing usable" {
  let both = ring()
  assert_eq(both.fingerprints(), [
    "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F", "66A22F1760CE2ABB10060451E2F97F5A50BD0EB3",
  ])
  // The public halves of a private key file are used.
  let from_secret = @sign.PublicKeyring::from_armored(fx_rsa_secret)
  assert_eq(from_secret.fingerprints(), [
    "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F",
  ])
  let binary = @sign.PublicKeyring::from_bytes(
    @armor.decode(fx_ed_public).data(),
  )
  assert_eq(binary.fingerprints(), ["66A22F1760CE2ABB10060451E2F97F5A50BD0EB3"])
  assert_true(
    outcome(() => @sign.PublicKeyring::from_armored("")) is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.PublicKeyring::from_armored("nothing"))
    is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.PublicKeyring::from_bytes(b"")) is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.PublicKeyring::from_bytes(b"\xff\xff"))
    is Err(@sign.Key(..)),
  )
  // A signature file has no key in it.
  assert_true(
    outcome(() => @sign.PublicKeyring::from_armored(fx_rsa_sig_armored))
    is Err(@sign.Key(..)),
  )
}

///|
test "errors print readable messages" {
  assert_eq("\{@sign.SignError::Key(message="x")}", "key: x")
  assert_eq("\{@sign.SignError::Invalid(message="y")}", "y")
  assert_eq("\{@sign.SignError::BadSignature(message="z")}", "bad signature: z")
}

///|
test "a signature of a 100 KB input with a 3-part hash equals the one-piece hash" {
  // Large input goes through the incremental hash and must agree with gpg's view.
  let big = Bytes::makei(100000, i => (i % 251).to_byte())
  let key = ed_key()
  let signature = key.detached(big[:], created~)
  let verified = ring().verify_detached(big[:], signature)
  assert_eq(verified.created, created)
}

///|
test "plain RSA signatures: sign, export the PEM key, verify" {
  let key = rsa_key()
  let data = b"control stream bytes"
  for hash in [@sign.RsaHash::Sha1, @sign.RsaHash::Sha256] {
    let signature = key.rsa_sign(hash, data[:])
    assert_eq(signature.length(), 256)
    assert_eq(signature, key.rsa_sign(hash, data[:]))
    let pem = @sign.PublicKeyring::from_pem(key.rsa_public_pem())
    let who = pem.verify_rsa(hash, data[:], signature[:])
    assert_true(who.has_prefix("RSA:"))
    // The OpenPGP public key verifies it as well, and names its fingerprint.
    let openpgp = @sign.PublicKeyring::from_armored(fx_rsa_public)
    assert_eq(
      openpgp.verify_rsa(hash, data[:], signature[:]),
      "7D8AA52BF6463DA4C2FA7FD803D2E4B8FA9AC68F",
    )
    // Other data, the other hash and the other key do not.
    assert_true(
      outcome(() => pem.verify_rsa(hash, b"other"[:], signature[:]))
      is Err(@sign.BadSignature(..)),
    )
    let other_hash = if hash == @sign.RsaHash::Sha1 {
      @sign.RsaHash::Sha256
    } else {
      @sign.RsaHash::Sha1
    }
    assert_true(
      outcome(() => pem.verify_rsa(other_hash, data[:], signature[:])) is Err(_),
    )
    assert_true(
      outcome(() => ring().verify_rsa(hash, b"other"[:], signature[:]))
      is Err(_),
    )
  }
  // from_armored accepts a PEM block too.
  let pem_text = key.rsa_public_pem()
  assert_true(pem_text.has_prefix("-----BEGIN PUBLIC KEY-----\n"))
  assert_true(pem_text.has_suffix("-----END PUBLIC KEY-----\n"))
  let same = @sign.PublicKeyring::from_armored(pem_text)
  assert_true(
    outcome(() => {
      same.verify_rsa(Sha256, data[:], key.rsa_sign(Sha256, data[:])[:])
    })
    is Ok(_),
  )
}

///|
test "plain RSA signatures need an RSA key" {
  let ed = ed_key()
  assert_true(outcome(() => ed.rsa_sign(Sha256, b"x"[:])) is Err(@sign.Key(..)))
  assert_true(outcome(() => ed.rsa_public_pem()) is Err(@sign.Key(..)))
}

///|
test "PEM public keys: damaged and foreign ones are refused" {
  let good = rsa_key().rsa_public_pem()
  assert_true(
    outcome(() => @sign.PublicKeyring::from_pem("")) is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => @sign.PublicKeyring::from_pem("-----BEGIN PUBLIC KEY-----\n"))
    is Err(@sign.Key(..)),
  )
  assert_true(
    outcome(() => {
      @sign.PublicKeyring::from_pem(
        "-----BEGIN PUBLIC KEY-----\n!!!!\n-----END PUBLIC KEY-----\n",
      )
    })
    is Err(@sign.Key(..)),
  )
  // Cut the key short at every length: an error, never a crash.
  let lines = good.split("\n").map(l => l.to_owned()).collect()
  let body = lines[1:lines.length() - 2].join("")
  for n in 0..<body.length() {
    if n % 7 == 0 {
      let text = "-----BEGIN PUBLIC KEY-----\n" +
        body[0:n].to_owned() +
        "\n-----END PUBLIC KEY-----\n"
      assert_true(outcome(() => @sign.PublicKeyring::from_pem(text)) is Err(_))
    }
  }
  // An EC key (id-ecPublicKey) is not an RSA key.
  let ec = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZ3xtSCSyZWGJEwwG5xkPLK5/EeAm\nvOQA3s0S0G6yaS9bPNVcbZ6vDHkE3fX2XGsU4G0e5okRdd7IUWZ0C4O/Pg==\n-----END PUBLIC KEY-----\n"
  assert_true(
    outcome(() => @sign.PublicKeyring::from_pem(ec)) is Err(@sign.Key(..)),
  )
}

///|
test "golden: PEM key and RSA signatures are the same on every backend" {
  let key = rsa_key()
  let pem = key.rsa_public_pem()
  assert_eq(
    hex_of_sha256(@utf8.encode(pem)),
    "50d0cdf7d13f015f9ef2cbade7654226e13c351878be95f7f3b075c39b5db765",
  )
  assert_eq(
    hex_of_sha256(key.rsa_sign(Sha256, b"control stream bytes"[:])),
    "950c18ca680dae06a857f574144220dd382a2435ad62d286d8da8d1686e9b41d",
  )
  assert_eq(
    hex_of_sha256(key.rsa_sign(Sha1, b"control stream bytes"[:])),
    "8b4bc3d2fb533722a576cb90b7a42625e2b5a1805077c2785cf667ec0a7e7813",
  )
}

///|
fn hex_of_sha256(bytes : Bytes) -> String {
  to_hex(Bytes::from_iter(@crypto.sha256(bytes).iter()))
}
