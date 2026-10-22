///|
fn file_named(files : Array[(String, Bytes)], name : String) -> Bytes {
  match files.filter(f => f.0 == name) {
    [f] => f.1
    _ => abort("no file \{name}")
  }
}

///|
fn hex_sha256(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}

///|
test "the hashes in Packages are those of the deb files" {
  let packages = debs()
  let index = @repo.apt_index(packages, date=1700000000L)
  let text = @utf8.decode_lossy(file_named(index, "Packages"))
  for deb in packages {
    assert_true(text.contains("SHA256: \{hex_sha256(deb.data)}\n"))
    assert_true(text.contains("Size: \{deb.data.length()}\n"))
    assert_true(
      text.contains(
        "MD5sum: \{@crypto.bytes_to_hex_string(@crypto.md5(deb.data))}\n",
      ),
    )
  }
}

///|
test "Packages.gz and Packages.xz unpack to Packages" {
  let index = @repo.apt_index(debs(), date=1)
  let plain = file_named(index, "Packages")
  assert_eq(
    @compress.decompress(file_named(index, "Packages.gz")[:], Gzip),
    plain,
  )
  assert_eq(
    @compress.decompress(file_named(index, "Packages.xz")[:], Xz),
    plain,
  )
}

///|
test "Release lists the size and SHA-256 of every index file" {
  let index = @repo.apt_index(debs(), date=1)
  let release = @utf8.decode_lossy(file_named(index, "Release"))
  for name in ["Packages", "Packages.gz", "Packages.xz"] {
    let data = file_named(index, name)
    assert_true(release.contains("\{hex_sha256(data)} "))
    assert_true(release.contains(" \{data.length()} \{name}\n"))
  }
}

///|
test "file names are ordered by their bytes, not by their length" {
  let base = debs()[0].data
  let names = ["a9.deb", "a10.deb", "B.deb", "a.deb"]
  let packages = names.map(n => pf(n, base))
  let index = @repo.apt_index(packages, date=1)
  let text = @utf8.decode_lossy(file_named(index, "Packages"))
  let at = (n : String) => text.find("Filename: ./\{n}\n").unwrap()
  assert_true(at("B.deb") < at("a.deb"))
  assert_true(at("a.deb") < at("a10.deb"))
  assert_true(at("a10.deb") < at("a9.deb"))
}

///|
test "an empty repository has an empty Packages and still a Release" {
  let index = @repo.apt_index([], date=1)
  assert_eq(file_named(index, "Packages"), b"")
  assert_true(
    @utf8.decode_lossy(file_named(index, "Release")).has_prefix("Date: "),
  )
}

///|
test "rfc2822 around leap days and century years" {
  inspect(@repo.rfc2822(1709164800L), content="Thu, 29 Feb 2024 00:00:00 +0000")
  inspect(@repo.rfc2822(1709251200L), content="Fri, 01 Mar 2024 00:00:00 +0000")
  inspect(@repo.rfc2822(4107542400L), content="Mon, 01 Mar 2100 00:00:00 +0000")
  inspect(@repo.rfc2822(946684800L), content="Sat, 01 Jan 2000 00:00:00 +0000")
  inspect(@repo.rfc2822(2147483647L), content="Tue, 19 Jan 2038 03:14:07 +0000")
}

///|
test "repomd.xml checksums are those of the compressed and of the plain files" {
  let index = @repo.yum_index(rpms(), timestamp=1700000000L)
  let repomd = @utf8.decode_lossy(file_named(index, "repodata/repomd.xml"))
  for file in index.filter(f => f.0 != "repodata/repomd.xml") {
    let packed = hex_sha256(file.1)
    let plain = hex_sha256(@compress.decompress(file.1[:], Gzip))
    assert_true(repomd.contains(">\{packed}</checksum>"))
    assert_true(repomd.contains(">\{plain}</open-checksum>"))
    assert_true(file.0.contains(packed))
  }
}

///|
test "check_yum reports a missing metadata file" {
  let packages = rpms()
  let index = @repo.yum_index(packages, timestamp=1)
  let cut = index.filter(f => !f.0.has_suffix("-filelists.xml.gz"))
  assert_true(@repo.check_yum(cut, packages).length() >= 1)
}

///|
test "check_apt reports changed packages and a missing Release" {
  let packages = debs()
  let index = @repo.apt_index(packages, date=1)
  assert_true(
    @repo.check_apt(index.filter(f => f.0 != "Release"), packages).length() >= 1,
  )
  let other = [packages[0]]
  assert_true(@repo.check_apt(index, other).length() >= 1)
}

///|
test "the newest time in a package decides the repository date" {
  let old = spec_of("old", "1.0", All)
  let newer = @spec.PackageSpec::new(
    name="newer",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="J <j@e.org>",
    description="D",
    entries=[@spec.Entry::file("/x", b"x", mtime=1800000000L)],
    mtime=1700000000L,
  )
  assert_eq(@repo.deb_time(pf("old.deb", @deb.build(old))), 1700000000L)
  assert_eq(@repo.deb_time(pf("newer.deb", @deb.build(newer))), 1800000000L)
  assert_eq(@repo.rpm_time(pf("newer.rpm", @rpm.build(newer))), 1700000000L)
}

///|
test "signed repositories never contain key material" {
  let key = @sign.SigningKey::from_armored(fx_ed_secret)
  let index = @repo.apt_index(debs(), date=1)
  let signed = @repo.sign_apt(index, key, created=1800000000L)
  for file in index + signed {
    let text = @utf8.decode_lossy(file.1)
    assert_false(text.contains("PRIVATE KEY"))
  }
}
