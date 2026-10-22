///|
fn key_rsa() -> @sign.SigningKey raise @sign.SignError {
  @sign.SigningKey::from_armored(fx_rsa_secret)
}

///|
fn ring_both() -> @sign.PublicKeyring raise @sign.SignError {
  @sign.PublicKeyring::from_armored(fx_rsa_public + "\n" + fx_ed_public)
}

///|
fn rejected(f : () -> Unit raise @sign.SignError) -> Bool {
  try {
    f()
    false
  } catch {
    _ => true
  }
}

///|
test "signature_info names the signer and the time of gpg's own signatures" {
  let rsa = @sign.signature_info(@utf8.encode(fx_rsa_sig_armored))
  assert_eq(rsa.key_id, "03D2E4B8FA9AC68F")
  assert_true(rsa.created > 1700000000L)
  let ed = @sign.signature_info(@utf8.encode(fx_ed_sig_armored))
  assert_eq(ed.key_id, "E2F97F5A50BD0EB3")
}

///|
test "signature_info reads ours and refuses empty or foreign data" {
  let signature = key_rsa().detached(b"x"[:], created=1800000000L)
  let info = @sign.signature_info(signature)
  assert_eq(info.key_id, "03D2E4B8FA9AC68F")
  assert_eq(info.created, 1800000000L)
  assert_true(rejected(() => ignore(@sign.signature_info(b""))))
  assert_true(
    rejected(() => ignore(@sign.signature_info(b"not a signature at all"))),
  )
}

///|
test "the signing time is never earlier than the key" {
  let key = key_rsa()
  assert_eq(key.signing_time(0L), key.created())
  assert_eq(key.signing_time(key.created() - 1L), key.created())
  assert_eq(key.signing_time(key.created() + 5L), key.created() + 5L)
  assert_true(key.created() > 1700000000L)
}

///|
test "a cleartext message with many lines starting with dashes round-trips" {
  let key = key_rsa()
  let lines = Array::makei(50, i => "-line \{i}\n--- rule\n- already")
  let text = lines.join("\n") + "\n"
  let message = key.cleartext(text, created=1800000000L)
  assert_true(message.contains("\n- -line 0\n"))
  assert_true(message.contains("\n- --- rule\n"))
  let (back, _) = ring_both().verify_cleartext(message)
  assert_eq(back, text)
}

///|
test "a cleartext message of 200 KB and non-ASCII text verifies" {
  let key = key_rsa()
  let text = "grüße 日本語 — line\n".repeat(8000)
  let (back, who) = ring_both().verify_cleartext(
    key.cleartext(text, created=1800000000L),
  )
  assert_eq(back, text)
  assert_eq(who.key_id, key.key_id())
}

///|
test "a cleartext message with Windows line endings verifies as the same text" {
  let key = key_rsa()
  let message = key.cleartext("one\ntwo\n", created=1800000000L)
  let crlf = message.replace_all(old="\n", new="\r\n")
  let (back, _) = ring_both().verify_cleartext(crlf)
  assert_eq(back, "one\ntwo\n")
}

///|
test "the Hash header is informational: the signature decides" {
  let key = key_rsa()
  let message = key.cleartext("text\n", created=1800000000L)
  let other = message.replace(old="Hash: SHA256", new="Hash: SHA1")
  let (back, _) = ring_both().verify_cleartext(other)
  assert_eq(back, "text\n")
}

///|
test "text between the markers may not be changed by a single space" {
  let key = key_rsa()
  let message = key.cleartext("alpha\nbeta\n", created=1800000000L)
  assert_true(
    rejected(() => {
      ignore(
        ring_both().verify_cleartext(message.replace(old="alpha", new="alpha!")),
      )
    }),
  )
  assert_true(
    rejected(() => {
      ignore(
        ring_both().verify_cleartext(message.replace(old="beta", new="bet a")),
      )
    }),
  )
  assert_true(
    rejected(() => {
      ignore(
        ring_both().verify_cleartext(
          message.replace(old="alpha\n", new="alpha\n\n"),
        ),
      )
    }),
  )
}

///|
test "trailing spaces in the signed text do not matter, inner ones do" {
  let key = key_rsa()
  let message = key.cleartext("a b\n", created=1800000000L)
  let padded = message.replace(old="a b\n", new="a b   \t\n")
  let (text, _) = ring_both().verify_cleartext(padded)
  assert_true(text.has_prefix("a b"))
  assert_true(
    rejected(() => {
      ignore(
        ring_both().verify_cleartext(message.replace(old="a b", new="a  b")),
      )
    }),
  )
}

///|
test "detached signatures of an empty input and of one byte" {
  let key = key_rsa()
  for data in [b"", b"\x00", b"\xff"] {
    let signature = key.detached(data[:], created=1800000000L)
    ignore(ring_both().verify_detached(data[:], signature))
    assert_true(
      rejected(() => ignore(ring_both().verify_detached(b"other"[:], signature))),
    )
  }
}

///|
test "armored detached signatures are readable with extra blank lines and CRLF" {
  let key = key_rsa()
  let armored = key.detached_armored(b"data"[:], created=1800000000L)
  let crlf = armored.replace_all(old="\n", new="\r\n")
  ignore(ring_both().verify_detached(b"data"[:], @utf8.encode(crlf)))
  ignore(
    ring_both().verify_detached(b"data"[:], @utf8.encode("\n\n" + armored)),
  )
}

///|
test "a keyring with the same key twice still verifies" {
  let double = @sign.PublicKeyring::from_armored(
    fx_rsa_public + "\n" + fx_rsa_public,
  )
  assert_eq(double.fingerprints().length(), 2)
  let signature = key_rsa().detached(b"x"[:], created=1800000000L)
  assert_eq(
    double.verify_detached(b"x"[:], signature).key_id,
    "03D2E4B8FA9AC68F",
  )
}

///|
test "signatures by a different key of the same keyring name that key" {
  let ed = @sign.SigningKey::from_armored(fx_ed_secret)
  let signature = ed.detached(b"hello"[:], created=1800000000L)
  let who = ring_both().verify_detached(b"hello"[:], signature)
  assert_eq(who.fingerprint, ed.fingerprint())
  assert_true(who.fingerprint != key_rsa().fingerprint())
}

///|
test "fingerprints are 40 capital hexadecimal digits and key ids their tail" {
  for key in [key_rsa(), @sign.SigningKey::from_armored(fx_ed_secret)] {
    let fp = key.fingerprint()
    assert_eq(fp.length(), 40)
    assert_true(
      fp.iter().all(c => (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')),
    )
    assert_eq(fp[24:].to_owned(), key.key_id())
  }
}
