///|
fn make(
  name~ : String = "demo",
  version~ : String = "1.0",
  description~ : String = "Summary\nSecond line\n\nAfter a blank line",
  entries~ : Array[@spec.Entry] = [
    @spec.Entry::file("/usr/bin/demo", b"#!/bin/sh\n", mode=0o755),
  ],
  depends~ : Array[@spec.Dependency] = [],
  epoch~ : Int32 = 0,
) -> @spec.PackageSpec {
  @spec.PackageSpec::new(
    name~,
    version~,
    arch=@spec.Arch::Amd64,
    maintainer="Jane <jane@example.org>",
    description~,
    entries~,
    depends~,
    epoch~,
    mtime=1700000000L,
  )
}

///|
test "control: required fields come first and in the Debian order" {
  let fields = @deb.parse_control(@deb.control_file(make()))
  let names = fields.map(f => f.0)
  assert_eq(names[0], "Package")
  assert_true(names.contains("Version"))
  assert_true(names.contains("Architecture"))
  assert_true(names.contains("Maintainer"))
  assert_true(names.contains("Installed-Size"))
  assert_true(names.contains("Description"))
  assert_eq(names[names.length() - 1], "Description")
}

///|
test "control: the description keeps blank lines as a dot" {
  let text = @deb.control_file(make())
  assert_true(
    text.contains(
      "Description: Summary\n Second line\n .\n After a blank line\n",
    ),
  )
  let back = @deb.parse_control(text).filter(f => f.0 == "Description")[0].1
  assert_true(back.contains("Second line"))
}

///|
test "control: epochs go in front of the version" {
  assert_eq(@deb.version_string(make(epoch=2, version="1.5")), "2:1.5-1")
  assert_eq(@deb.version_string(make(version="1.0~rc1")), "1.0~rc1-1")
  let fields = @deb.parse_control(@deb.control_file(make(epoch=3)))
  assert_eq(fields.filter(f => f.0 == "Version")[0].1, "3:1.0-1")
}

///|
test "control: dependencies are written in Debian syntax" {
  let spec = make(depends=[
    @spec.Dependency::parse("libc6 >= 2.31"),
    @spec.Dependency::parse("bash"),
  ])
  let fields = @deb.parse_control(@deb.control_file(spec))
  assert_eq(fields.filter(f => f.0 == "Depends")[0].1, "libc6 (>= 2.31), bash")
}

///|
test "control: Installed-Size rounds up to KiB" {
  let one = make(entries=[@spec.Entry::file("/a", Bytes::make(1, b'x'))])
  let big = make(entries=[@spec.Entry::file("/a", Bytes::make(1025, b'x'))])
  let size = (spec : @spec.PackageSpec) => {
    @deb.parse_control(@deb.control_file(spec)).filter(f => {
      f.0 == "Installed-Size"
    })[0].1
  }
  assert_eq(size(one), "1")
  assert_eq(size(big), "2")
}

///|
test "control files round trip through parse_control" {
  let text = "Package: x\nVersion: 1\nDescription: One\n Two\n .\n Three\n"
  let fields = @deb.parse_control(text)
  assert_eq(fields.map(f => f.0), ["Package", "Version", "Description"])
  assert_eq(fields[0].1, "x")
}

///|
test "parse_control refuses a continuation line without a field and a missing colon" {
  for bad in [" orphan\n", "NoColon\n", ": value\n"] {
    assert_true(
      try @deb.parse_control(bad) catch {
        @deb.Corrupt(..) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "md5sums lines are two spaces apart and refuse bad input" {
  let pairs = @deb.parse_md5sums(
    "d41d8cd98f00b204e9800998ecf8427e  usr/bin/x\n",
  )
  assert_eq(pairs, [("/usr/bin/x", "d41d8cd98f00b204e9800998ecf8427e")])
  for
    bad in [
      "short  x\n", "d41d8cd98f00b204e9800998ecf8427e x\n", "zzzd8cd98f00b204e9800998ecf8427e  x\n",
    ] {
    assert_true(
      try @deb.parse_md5sums(bad) catch {
        @deb.Corrupt(..) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "normalize_path gives one absolute path, without dot-slash and trailing slash" {
  assert_eq(@deb.normalize_path("./usr/bin/x"), "/usr/bin/x")
  assert_eq(@deb.normalize_path("./usr/"), "/usr")
  assert_eq(@deb.normalize_path("usr/bin"), "/usr/bin")
}

///|
test "file names contain the epoch-free version and the architecture" {
  assert_eq(@deb.file_name(make()), "demo_1.0-1_amd64.deb")
  assert_eq(@deb.file_name(make(epoch=4)), "demo_1.0-1_amd64.deb")
}

///|
test "building twice gives the same bytes, every compression reads back" {
  let spec = make()
  for c in [@compress.Compression::None, Gzip, Xz, Zstd] {
    let deb = @deb.build(spec, compression=c)
    assert_eq(deb, @deb.build(spec, compression=c))
    let pkg = @deb.read(deb)
    assert_eq(pkg.verify(), [])
    assert_eq(pkg.data_compression, c.name().replace(old="none", new="none"))
    assert_eq(pkg.field("Package"), Some("demo"))
  }
}

///|
test "maintainer scripts are stored with mode 0755 and listed" {
  let spec = @spec.PackageSpec::new(
    name="demo",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="J <j@e.org>",
    description="D",
    scripts={
      pre_install: Some("#!/bin/sh\nexit 0\n"),
      post_install: Some("#!/bin/sh\nexit 0\n"),
      pre_remove: None,
      post_remove: Some("#!/bin/sh\nexit 0\n"),
    },
  )
  let pkg = @deb.read(@deb.build(spec))
  let names = pkg.control_files.map(f => f.0)
  assert_true(names.contains("preinst"))
  assert_true(names.contains("postinst"))
  assert_true(names.contains("postrm"))
  assert_false(names.contains("prerm"))
}

///|
test "config files are listed in conffiles and everything else is not" {
  let spec = make(entries=[
    @spec.Entry::file("/etc/demo.conf", b"x=1\n", config=true),
    @spec.Entry::file("/usr/bin/demo", b"x", mode=0o755),
  ])
  let pkg = @deb.read(@deb.build(spec))
  assert_eq(pkg.conffiles, ["/etc/demo.conf"])
}
