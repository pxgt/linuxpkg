///|
fn pkg(
  arch~ : @spec.Arch = @spec.Arch::Amd64,
  version~ : String = "1.2",
  release~ : String = "3",
  entries~ : Array[@spec.Entry] = [
    @spec.Entry::file("/usr/bin/demo", b"#!/bin/sh\n", mode=0o755),
  ],
  depends~ : Array[@spec.Dependency] = [],
) -> @spec.PackageSpec {
  @spec.PackageSpec::new(
    name="demo",
    version~,
    release~,
    arch~,
    maintainer="Jane <jane@example.org>",
    description="Summary\nMore",
    license="MIT",
    homepage="https://example.org/demo",
    depends~,
    entries~,
    mtime=1700000000L,
  )
}

///|
test "file names are name-version-rRELEASE.apk" {
  assert_eq(@apk.file_name(pkg()), "demo-1.2-r3.apk")
  assert_eq(@apk.file_name(pkg(release="1")), "demo-1.2-r1.apk")
}

///|
test "architecture names" {
  assert_eq(@apk.arch_name(@spec.Arch::Amd64), Some("x86_64"))
  assert_eq(@apk.arch_name(@spec.Arch::Arm64), Some("aarch64"))
  assert_eq(@apk.arch_name(@spec.Arch::All), Some("noarch"))
  assert_eq(@apk.arch_name(@spec.Arch::Armhf), Some("armv7"))
  assert_eq(@apk.arch_name(@spec.Arch::Mips64le), None)
}

///|
test "an architecture without an Alpine port is an error" {
  assert_true(
    try @apk.build(pkg(arch=Mips64le)) catch {
      @apk.Invalid(..) => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "versions with a tilde become Alpine pre-release suffixes" {
  let built = @apk.read(@apk.build(pkg(version="1.0~rc1")))
  assert_true(built.field("pkgver").unwrap().contains("_rc1"))
}

///|
test ".PKGINFO carries name, description, url, license and sizes" {
  let built = @apk.read(@apk.build(pkg()))
  assert_eq(built.field("pkgname"), Some("demo"))
  assert_eq(built.field("pkgver"), Some("1.2-r3"))
  assert_eq(built.field("pkgdesc"), Some("Summary"))
  assert_eq(built.field("url"), Some("https://example.org/demo"))
  assert_eq(built.field("license"), Some("MIT"))
  assert_eq(built.field("arch"), Some("x86_64"))
  assert_eq(built.field("size"), Some("10"))
  assert_eq(built.field("builddate"), Some("1700000000"))
}

///|
test "dependencies are listed one per line" {
  let built = @apk.read(
    @apk.build(
      pkg(depends=[
        @spec.Dependency::parse("musl >= 1.2"),
        @spec.Dependency::parse("bash"),
      ]),
    ),
  )
  assert_eq(built.fields("depend").length(), 2)
  assert_true(built.fields("depend")[1] == "bash")
}

///|
test "the data hash in .PKGINFO is the SHA-256 of the data stream" {
  let built = @apk.read(@apk.build(pkg()))
  assert_eq(
    built.field("datahash"),
    Some(@crypto.bytes_to_hex_string(@crypto.sha256(built.data_packed))),
  )
}

///|
test "every file and link carries its SHA-1 in a PAX record" {
  let built = @apk.read(
    @apk.build(
      pkg(entries=[
        @spec.Entry::file("/usr/bin/demo", b"abc", mode=0o755),
        @spec.Entry::symlink("/usr/bin/d", "demo"),
        @spec.Entry::dir("/var/lib/demo"),
      ]),
    ),
  )
  let sums = built.data.map(item => item.1.map(r => r.0))
  let files = built.data.filter(item => {
    item.0.path.has_suffix("demo") && !item.0.path.has_suffix("lib/demo")
  })
  assert_true(files.length() >= 1)
  for item in built.data {
    match item.0.kind {
      File(_) | Symlink(_) =>
        assert_true(item.1.map(r => r.0).contains("APK-TOOLS.checksum.SHA1"))
      _ => ()
    }
  }
  ignore(sums)
}

///|
test "the control stream has no end marker, the data stream has one" {
  let built = @apk.read(@apk.build(pkg()))
  let members = @compress.gzip_members(@apk.build(pkg())[:])
  assert_eq(members.length(), 2)
  assert_true(members[0].1.length() % 512 == 0)
  assert_eq(
    members[1].1[members[1].1.length() - 1024:].to_owned(),
    Bytes::make(1024, b'\x00'),
  )
  ignore(built)
}

///|
test "scripts go to the control stream under their apk names" {
  let spec = @spec.PackageSpec::new(
    name="demo",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="J <j@e.org>",
    description="D",
    scripts={
      pre_install: Some("#!/bin/sh\n"),
      post_install: Some("#!/bin/sh\n"),
      pre_remove: Some("#!/bin/sh\n"),
      post_remove: Some("#!/bin/sh\n"),
    },
  )
  let built = @apk.read(@apk.build(spec))
  let names = built.control_files.map(f => f.0)
  for
    want in [
      ".pre-install", ".post-install", ".pre-deinstall", ".post-deinstall",
    ] {
    assert_true(names.contains(want))
  }
}

///|
test "output is the same every time" {
  assert_eq(@apk.build(pkg()), @apk.build(pkg()))
  assert_true(@apk.build(pkg()) != @apk.build(pkg(version="1.3")))
}

///|
test "reading junk is an error" {
  for
    junk in [
      b"",
      b"plain",
      Bytes::make(100, b'\x00'),
      @compress.compress(b"just a gzip"[:], Gzip),
    ] {
    assert_true(
      try @apk.read(junk) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}
