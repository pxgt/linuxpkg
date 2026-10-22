///|
fn pf(name : String, data : Bytes) -> @repo.PackageFile {
  { name, data, }
}

///|
fn apks() -> Array[@repo.PackageFile] raise {
  let beta = spec_of("beta", "2.0", Amd64, depends=[
    @spec.Dependency::parse("alpha >= 1.0"),
  ])
  let alpha = spec_of("alpha", "1.0", All)
  [
    pf(@apk.file_name(beta), @apk.build(beta)),
    pf(@apk.file_name(alpha), @apk.build(alpha)),
  ]
}

///|
fn arch_packages() -> Array[@repo.PackageFile] raise {
  let beta = spec_of("beta", "2.0", Amd64, depends=[
    @spec.Dependency::parse("alpha >= 1.0"),
  ])
  let alpha = spec_of("alpha", "1.0", All)
  [
    pf(@arch.file_name(beta), @arch.build(beta)),
    pf(@arch.file_name(alpha), @arch.build(alpha, compression=Xz)),
  ]
}

///|
fn text_of(files : Array[(String, Bytes)], name : String) -> Bytes {
  match files.filter(f => f.0 == name) {
    [f] => f.1
    _ => abort("no file \{name}")
  }
}

///|
fn content_of(entry : @tar.Entry) -> String {
  match entry.kind {
    File(content) => @utf8.decode_lossy(content[:])
    _ => abort("not a file")
  }
}

///|
fn rsa_signer() -> @sign.SigningKey raise {
  @sign.SigningKey::from_armored(fx_rsa_secret)
}

///|
fn rsa_ring() -> @sign.PublicKeyring raise {
  @sign.PublicKeyring::from_pem(rsa_signer().rsa_public_pem())
}

///|
fn fails(f : () -> Unit raise @repo.RepoError) -> Bool {
  try {
    f()
    false
  } catch {
    @repo.Invalid(..) => true
  }
}

///|
test "apk index: directories, entries and reproducibility" {
  let packages = apks()
  let files = @repo.apk_index(packages, description="demo", date=1700000000L)
  assert_eq(files.map(f => f.0), [
    "x86_64/APKINDEX.tar.gz", "x86_64/alpha-1.0-r1.apk", "x86_64/beta-2.0-r1.apk",
    "noarch/alpha-1.0-r1.apk",
  ])
  // Read the index back: DESCRIPTION and APKINDEX, the entries in name order.
  let members = @compress.gzip_members(
    text_of(files, "x86_64/APKINDEX.tar.gz")[:],
    max_size=1000000,
  )
  assert_eq(members.length(), 1)
  let entries = @tar.parse(members[0].1)
  assert_eq(entries.map(e => e.path), ["DESCRIPTION", "APKINDEX"])
  assert_eq(entries.map(e => e.mtime), [1700000000L, 1700000000L])
  assert_eq(content_of(entries[0]), "demo")
  let text = content_of(entries[1])
  assert_true(text.contains("P:alpha\nV:1.0-r1\nA:noarch\n"))
  assert_true(text.contains("P:beta\nV:2.0-r1\nA:x86_64\n"))
  assert_true(text.contains("\nD:alpha>=1.0\n"))
  assert_true(text.has_suffix("\n\n"))
  assert_eq(@repo.check_apk(files, packages), [])
  // Same result for the other order of the input.
  let reversed = @repo.apk_index(
    [packages[1], packages[0]],
    description="demo",
    date=1700000000L,
  )
  assert_eq(reversed, files)
}

///|
test "apk index of noarch packages only has both common architectures" {
  let alpha = spec_of("alpha", "1.0", All)
  let packages = [pf(@apk.file_name(alpha), @apk.build(alpha))]
  let files = @repo.apk_index(packages, description="", date=0L)
  assert_eq(files.map(f => f.0), [
    "aarch64/APKINDEX.tar.gz", "aarch64/alpha-1.0-r1.apk", "x86_64/APKINDEX.tar.gz",
    "x86_64/alpha-1.0-r1.apk", "noarch/alpha-1.0-r1.apk",
  ])
  // Without a description there is no DESCRIPTION file.
  let members = @compress.gzip_members(
    text_of(files, "x86_64/APKINDEX.tar.gz")[:],
    max_size=1000000,
  )
  assert_eq(@tar.parse(members[0].1).map(e => e.path), ["APKINDEX"])
  assert_eq(@repo.check_apk(files, packages), [])
  assert_eq(@repo.apk_index([], description="", date=0L), [])
}

///|
test "check_apk finds damage" {
  let packages = apks()
  let files = @repo.apk_index(packages, description="demo", date=1700000000L)
  let without = fn(name : String) { files.filter(f => f.0 != name) }
  assert_eq(@repo.check_apk(without("x86_64/APKINDEX.tar.gz"), packages), [
    "x86_64/APKINDEX.tar.gz: missing",
  ])
  assert_eq(@repo.check_apk(without("noarch/alpha-1.0-r1.apk"), packages), [
    "noarch/alpha-1.0-r1.apk: missing or different from the package",
  ])
  let changed = files.map(f => {
    if f.0 == "x86_64/beta-2.0-r1.apk" {
      (f.0, b"changed")
    } else {
      f
    }
  })
  assert_true(@repo.check_apk(changed, packages).length() >= 1)
  // An index of other packages.
  let other = @repo.apk_index(
    [packages[1]],
    description="demo",
    date=1700000000L,
  )
  let swapped = files.map(f => {
    if f.0 == "x86_64/APKINDEX.tar.gz" {
      (f.0, text_of(other, "x86_64/APKINDEX.tar.gz"))
    } else {
      f
    }
  })
  assert_true(@repo.check_apk(swapped, packages).length() >= 1)
  let garbage = files.map(f => {
    if f.0 == "x86_64/APKINDEX.tar.gz" {
      (f.0, b"not gzip")
    } else {
      f
    }
  })
  assert_true(@repo.check_apk(garbage, packages).length() >= 1)
  // A package that is not an apk.
  assert_true(@repo.check_apk(files, [pf("x.apk", b"nope")]).length() >= 1)
}

///|
test "apk_index refuses bad input" {
  let alpha = spec_of("alpha", "1.0", All)
  let data = @apk.build(alpha)
  for
    bad in [
      [pf("x.apk", b"nope")],
      [pf("alpha.deb", data)],
      [pf("a b.apk", data)],
      [pf("a/b.apk", data)],
      [pf("a.apk", data), pf("a.apk", data)],
    ] {
    assert_true(
      fails(() => ignore(@repo.apk_index(bad, description="", date=0L))),
    )
  }
}

///|
test "sign_apk: signed indexes pass, unsigned, changed and foreign ones fail" {
  let packages = apks()
  let files = @repo.apk_index(packages, description="demo", date=1700000000L)
  let key = rsa_signer()
  let signed = @repo.sign_apk(
    files,
    key,
    key_name="mine.rsa.pub",
    created=1700000000L,
  )
  assert_eq(signed.map(f => f.0), ["x86_64/APKINDEX.tar.gz"])
  let all = files.map(f => {
    match signed.filter(s => s.0 == f.0) {
      [s] => s
      _ => f
    }
  })
  assert_eq(@repo.check_apk_signature(all, rsa_ring()), [])
  // The signed index still reads and checks as an index.
  assert_eq(@repo.check_apk(all, packages), [])
  // Unsigned.
  assert_eq(@repo.check_apk_signature(files, rsa_ring()), [
    "x86_64/APKINDEX.tar.gz: not signed",
  ])
  assert_eq(@repo.check_apk_signature([], rsa_ring()), ["no APKINDEX.tar.gz"])
  // Another key.
  let stranger = @sign.PublicKeyring::from_armored(fx_ed_public)
  assert_eq(@repo.check_apk_signature(all, stranger).length(), 1)
  // The index changed after signing: flip a byte of the index stream.
  let index = text_of(all, "x86_64/APKINDEX.tar.gz").to_array()
  index[index.length() - 12] = index[index.length() - 12] ^ 1
  let damaged = all.map(f => {
    if f.0 == "x86_64/APKINDEX.tar.gz" {
      (f.0, Bytes::from_array(index))
    } else {
      f
    }
  })
  assert_eq(@repo.check_apk_signature(damaged, rsa_ring()).length(), 1)
  // Ed25519 keys cannot sign Alpine indexes.
  let ed = @sign.SigningKey::from_armored(fx_ed_secret)
  assert_true(
    fails(() => {
      ignore(@repo.sign_apk(files, ed, key_name="k.rsa.pub", created=0L))
    }),
  )
}

///|
test "arch database: files, desc fields and the file list" {
  let packages = arch_packages()
  let files = @repo.arch_index(packages, [], name="demo", date=1700000000L)
  assert_eq(files.map(f => f.0), [
    "demo.db.tar.gz", "demo.db", "demo.files.tar.gz", "demo.files",
  ])
  assert_eq(text_of(files, "demo.db"), text_of(files, "demo.db.tar.gz"))
  assert_eq(text_of(files, "demo.files"), text_of(files, "demo.files.tar.gz"))
  let db = @compress.gzip_members(
    text_of(files, "demo.db")[:],
    max_size=1000000,
  )
  let entries = @tar.parse(db[0].1)
  assert_eq(entries.map(e => e.path), [
    "alpha-1.0-1/", "alpha-1.0-1/desc", "beta-2.0-1/", "beta-2.0-1/desc",
  ])
  let desc = content_of(entries[3])
  // The order and shape of the desc file that repo-add writes.
  let want_start = "%FILENAME%\nbeta-2.0-1-x86_64.pkg.tar.zst\n\n%NAME%\nbeta\n\n%BASE%\nbeta\n\n%VERSION%\n2.0-1\n\n%DESC%\nPackage beta\n\n%CSIZE%\n"
  assert_true(desc.has_prefix(want_start))
  for
    field in [
      "%ISIZE%\n", "%SHA256SUM%\n", "%URL%\nhttps://example.org/beta\n\n", "%LICENSE%\nMIT\n\n",
      "%ARCH%\nx86_64\n\n", "%BUILDDATE%\n1700000000\n\n", "%PACKAGER%\nJane <jane@example.org>\n\n",
      "%PROVIDES%\nbeta-api=2\n\n", "%DEPENDS%\nalpha>=1.0\n\n",
    ] {
    assert_true(desc.contains(field))
  }
  assert_false(desc.contains("%PGPSIG%"))
  assert_false(desc.contains("%FILES%"))
  // The files database also holds the list of files, without the metadata files.
  let files_db = @compress.gzip_members(
    text_of(files, "demo.files")[:],
    max_size=1000000,
  )
  let file_entries = @tar.parse(files_db[0].1)
  assert_eq(file_entries.length(), 6)
  let list = content_of(file_entries[5])
  assert_eq(
    list, "%FILES%\netc/\netc/beta.conf\nusr/\nusr/bin/\nusr/bin/beta\nusr/share/\nusr/share/beta/\nusr/share/beta/data.txt\n\n",
  )
  assert_false(list.contains(".PKGINFO"))
  assert_eq(@repo.check_arch(files, packages, [], name="demo"), [])
  // Deterministic and independent of the order of the input.
  assert_eq(
    @repo.arch_index(
      [packages[1], packages[0]],
      [],
      name="demo",
      date=1700000000L,
    ),
    files,
  )
}

///|
test "arch database records the package signature" {
  let packages = arch_packages()
  let key = rsa_signer()
  let signatures = packages.map(p => {
    pf(p.name + ".sig", key.detached(p.data[:], created=1700000000L))
  })
  let files = @repo.arch_index(packages, signatures, name="demo", date=0L)
  let db = @compress.gzip_members(
    text_of(files, "demo.db")[:],
    max_size=1000000,
  )
  let entries = @tar.parse(db[0].1)
  assert_true(content_of(entries[1]).contains("%PGPSIG%\n"))
  assert_eq(@repo.check_arch(files, packages, signatures, name="demo"), [])
  // Without the signatures the entries differ, and the check notices.
  assert_true(@repo.check_arch(files, packages, [], name="demo").length() >= 1)
}

///|
test "sign_arch signs the databases and check_arch_signature reads it" {
  let packages = arch_packages()
  let files = @repo.arch_index(packages, [], name="demo", date=1700000000L)
  let key = rsa_signer()
  let signed = @repo.sign_arch(files, key, created=1700000000L)
  assert_eq(signed.length(), 4)
  let ring = @sign.PublicKeyring::from_armored(fx_rsa_public)
  assert_eq(@repo.check_arch_signature(files + signed, ring, name="demo"), [])
  assert_eq(@repo.check_arch(files + signed, packages, [], name="demo"), [])
  // Missing, foreign and outdated signatures.
  assert_eq(@repo.check_arch_signature(files, ring, name="demo").length(), 4)
  let stranger = @sign.PublicKeyring::from_armored(fx_ed_public)
  assert_eq(
    @repo.check_arch_signature(files + signed, stranger, name="demo").length(),
    4,
  )
  let changed = (files + signed).map(f => {
    if f.0 == "demo.db" {
      (f.0, b"changed")
    } else {
      f
    }
  })
  assert_eq(@repo.check_arch_signature(changed, ring, name="demo").length(), 1)
}

///|
test "arch_index refuses bad input" {
  let packages = arch_packages()
  for name in ["", "a b", "a/b"] {
    assert_true(
      fails(() => ignore(@repo.arch_index(packages, [], name~, date=0L))),
    )
  }
  for
    bad in [
      [pf("x.pkg.tar.zst", b"nope")],
      [pf("alpha.deb", packages[0].data)],
      [pf("a b.pkg.tar.zst", packages[0].data)],
      [packages[0], packages[0]],
    ] {
    assert_true(
      fails(() => ignore(@repo.arch_index(bad, [], name="demo", date=0L))),
    )
  }
  assert_true(@repo.check_arch([], packages, [], name="demo").length() >= 2)
}

///|
test "build times of apk and Arch packages" {
  assert_eq(@repo.apk_time(apks()[0]), 1700000000L)
  assert_eq(@repo.arch_time(arch_packages()[0]), 1700000000L)
  assert_true(fails(() => ignore(@repo.apk_time(pf("x.apk", b"no")))))
  assert_true(fails(() => ignore(@repo.arch_time(pf("x.pkg.tar", b"no")))))
}
