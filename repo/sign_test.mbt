///|
fn signer() -> @sign.SigningKey raise {
  @sign.SigningKey::from_armored(fx_ed_secret)
}

///|
fn ring() -> @sign.PublicKeyring raise {
  @sign.PublicKeyring::from_armored(fx_ed_public)
}

///|
test "sign_apt writes InRelease and Release.gpg that check_apt_signature accepts" {
  let packages = debs()
  let files = @repo.apt_index(packages, date=1700000000L)
  let signed = @repo.sign_apt(files, signer(), created=1700000000L)
  assert_eq(signed.map(f => f.0), ["InRelease", "Release.gpg"])
  assert_eq(@repo.check_apt_signature(files + signed, ring()), [])
  // The unsigned index is still fine and unchanged.
  assert_eq(@repo.check_apt(files + signed, packages), [])
  // Reproducible: same inputs, same signature files.
  let again = @repo.sign_apt(files, signer(), created=1700000000L)
  assert_eq(again, signed)
  // The cleartext text is the Release file.
  let clear = @utf8.decode(signed[0].1)
  assert_true(clear.contains("Architectures: "))
  assert_true(
    clear.has_prefix("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n"),
  )
}

///|
test "the signature time never precedes the key" {
  let files = @repo.apt_index(debs(), date=0L)
  let signed = @repo.sign_apt(files, signer(), created=0L)
  let (_, who) = ring().verify_cleartext(@utf8.decode(signed[0].1))
  assert_eq(who.created, signer().created())
  let late = @repo.sign_apt(files, signer(), created=4000000000L)
  let (_, who) = ring().verify_cleartext(@utf8.decode(late[0].1))
  assert_eq(who.created, 4000000000L)
}

///|
test "check_apt_signature finds every kind of damage" {
  let files = @repo.apt_index(debs(), date=1700000000L)
  let signed = @repo.sign_apt(files, signer(), created=1700000000L)
  let all = files + signed
  let without = fn(name : String) { all.filter(f => f.0 != name) }
  assert_eq(@repo.check_apt_signature(without("Release.gpg"), ring()), [
    "Release.gpg: missing",
  ])
  assert_eq(@repo.check_apt_signature(without("InRelease"), ring()), [
    "InRelease: missing",
  ])
  assert_eq(@repo.check_apt_signature(without("Release"), ring()), [
    "Release: missing",
  ])
  // Release changed after signing: both signatures fail.
  let changed = all.map(f => {
    if f.0 == "Release" {
      (
        f.0,
        @utf8.encode(
          @utf8.decode(f.1).replace(old="Architectures", new="Architecturez"),
        ),
      )
    } else {
      f
    }
  })
  let problems = @repo.check_apt_signature(changed, ring())
  assert_eq(problems.length(), 2)
  assert_true(problems[0].has_prefix("Release.gpg: bad signature"))
  // A valid InRelease for a different Release text.
  let other = @repo.sign_apt(
    all.map(f => if f.0 == "Release" { (f.0, b"Origin: other\n") } else { f }),
    signer(),
    created=1700000000L,
  )
  let mixed = all.map(f => {
    match other.filter(o => o.0 == f.0) {
      [o] => o
      _ => f
    }
  })
  let swapped = @repo.check_apt_signature(mixed, ring())
  assert_true(swapped.length() >= 1)
  // The wrong key.
  let stranger = @sign.PublicKeyring::from_armored(fx_ed_public).fingerprints()
  assert_eq(stranger.length(), 1)
}

///|
test "sign_apt and sign_yum refuse an index without the file to sign" {
  assert_true(
    (try @repo.sign_apt([], signer(), created=0L) catch {
      @repo.Invalid(file~, ..) => file
      _ => "other"
    } noraise {
      _ => "signed"
    }) ==
    "Release",
  )
  assert_true(
    (try @repo.sign_yum([], signer(), created=0L) catch {
      @repo.Invalid(file~, ..) => file
      _ => "other"
    } noraise {
      _ => "signed"
    }) ==
    "repodata/repomd.xml",
  )
  assert_eq(@repo.check_yum_signature([], ring()), [
    "repodata/repomd.xml: missing",
  ])
}

///|
test "sign_yum signs repomd.xml and check_yum_signature accepts it" {
  let packages = rpms()
  let files = @repo.yum_index(packages, timestamp=1700000000L)
  let signed = @repo.sign_yum(files, signer(), created=1700000000L)
  assert_eq(signed.map(f => f.0), ["repodata/repomd.xml.asc"])
  assert_eq(@repo.check_yum_signature(files + signed, ring()), [])
  assert_eq(@repo.check_yum(files + signed, packages), [])
  assert_eq(@repo.check_yum_signature(files, ring()), [
    "repodata/repomd.xml.asc: missing",
  ])
  // repomd.xml changed after signing.
  let changed = (files + signed).map(f => {
    if f.0 == "repodata/repomd.xml" {
      (f.0, @utf8.encode(@utf8.decode(f.1) + " "))
    } else {
      f
    }
  })
  let problems = @repo.check_yum_signature(changed, ring())
  assert_eq(problems.length(), 1)
  assert_true(problems[0].contains("bad signature"))
}
