///|
fn demo(
  arch~ : @spec.Arch = @spec.Arch::Amd64,
  release~ : String = "1",
  entries~ : Array[@spec.Entry] = [
    @spec.Entry::file("/usr/bin/demo", b"#!/bin/sh\n", mode=0o755),
  ],
  depends~ : Array[@spec.Dependency] = [],
  provides~ : Array[@spec.Dependency] = [],
) -> @spec.PackageSpec {
  @spec.PackageSpec::new(
    name="demo",
    version="1.2",
    release~,
    arch~,
    maintainer="Jane <jane@example.org>",
    description="Summary\nMore text",
    license="MIT",
    homepage="https://example.org/demo",
    depends~,
    provides~,
    entries~,
    mtime=1700000000L,
  )
}

///|
test "file names carry the version, release and architecture" {
  assert_eq(@arch.file_name(demo()), "demo-1.2-1-x86_64.pkg.tar.zst")
  assert_eq(@arch.file_name(demo(arch=Arm64)), "demo-1.2-1-aarch64.pkg.tar.zst")
  assert_eq(@arch.file_name(demo(arch=All)), "demo-1.2-1-any.pkg.tar.zst")
  assert_eq(
    @arch.file_name(demo(), compression=Xz),
    "demo-1.2-1-x86_64.pkg.tar.xz",
  )
  assert_eq(
    @arch.file_name(demo(), compression=Gzip),
    "demo-1.2-1-x86_64.pkg.tar.gz",
  )
  assert_eq(
    @arch.file_name(demo(), compression=None),
    "demo-1.2-1-x86_64.pkg.tar",
  )
}

///|
test "every compression builds a package that reads and verifies" {
  for c in [@compress.Compression::None, Gzip, Xz, Zstd] {
    let pkg = @arch.read(@arch.build(demo(), compression=c))
    assert_eq(pkg.verify(), [])
    assert_eq(pkg.field("pkgname"), Some("demo"))
    assert_eq(pkg.field("pkgver"), Some("1.2-1"))
  }
}

///|
test ".PKGINFO carries the architecture, size, license and url" {
  let pkg = @arch.read(@arch.build(demo()))
  assert_eq(pkg.field("arch"), Some("x86_64"))
  assert_eq(pkg.field("license"), Some("MIT"))
  assert_eq(pkg.field("url"), Some("https://example.org/demo"))
  assert_eq(pkg.field("builddate"), Some("1700000000"))
  assert_eq(pkg.field("size"), Some("10"))
  assert_eq(pkg.field("pkgdesc"), Some("Summary"))
}

///|
test "dependencies and provides are written one per line" {
  let pkg = @arch.read(
    @arch.build(
      demo(
        depends=[
          @spec.Dependency::parse("glibc >= 2.38"),
          @spec.Dependency::parse("bash"),
        ],
        provides=[@spec.Dependency::parse("demo-api = 2")],
      ),
    ),
  )
  assert_eq(pkg.fields("depend"), ["glibc>=2.38", "bash"])
  assert_eq(pkg.fields("provides"), ["demo-api=2"])
}

///|
test "a provide with a version range is refused: pacman only takes =" {
  let spec = demo(provides=[@spec.Dependency::parse("demo-api >= 2")])
  assert_true(
    try @arch.build(spec) catch {
      @arch.Invalid(..) => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "config files become backup entries without the leading slash" {
  let pkg = @arch.read(
    @arch.build(
      demo(entries=[
        @spec.Entry::file("/etc/demo.conf", b"a=1\n", config=true),
        @spec.Entry::file("/usr/bin/demo", b"x", mode=0o755),
      ]),
    ),
  )
  assert_eq(pkg.fields("backup"), ["etc/demo.conf"])
}

///|
test ".MTREE lists every entry with size and SHA-256 for files" {
  let pkg = @arch.read(
    @arch.build(
      demo(entries=[
        @spec.Entry::file("/usr/bin/demo", b"abc", mode=0o755),
        @spec.Entry::symlink("/usr/bin/d", "demo"),
      ]),
    ),
  )
  let mtree = pkg.mtree.unwrap()
  let demo_entry = mtree.filter(m => m.path == "usr/bin/demo")[0]
  assert_eq(demo_entry.kind, "file")
  assert_eq(demo_entry.size, Some(3L))
  assert_eq(
    demo_entry.sha256,
    Some("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
  )
  let link = mtree.filter(m => m.path == "usr/bin/d")[0]
  assert_eq(link.link, Some("demo"))
}

///|
test "parse_mtree reads the escapes and defaults of an mtree file" {
  let entries = @arch.parse_mtree(
    "#mtree\n/set type=file uid=0 gid=0 mode=644\n./a\\040b time=1.0 size=2 sha256digest=aa\n./d type=dir mode=755\n",
  )
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].path, "a b")
  assert_eq(entries[1].kind, "dir")
}

///|
test "the first entries are .INSTALL, .MTREE and .PKGINFO in that order" {
  let spec = @spec.PackageSpec::new(
    name="demo",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="J <j@e.org>",
    description="D",
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\necho hi\n"),
      pre_remove: None,
      post_remove: None,
    },
  )
  let pkg = @arch.read(@arch.build(spec))
  assert_true(pkg.install.unwrap().contains("post_install()"))
  assert_eq(pkg.entries[0].path, ".INSTALL")
  assert_eq(pkg.entries[1].path, ".MTREE")
  assert_eq(pkg.entries[2].path, ".PKGINFO")
}

///|
test "releases must be numbers for pacman" {
  assert_true(
    try @arch.build(demo(release="alpha")) catch {
      @arch.Invalid(..) => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "output does not depend on anything but the input" {
  for c in [@compress.Compression::Gzip, Xz, Zstd] {
    assert_eq(
      @arch.build(demo(), compression=c),
      @arch.build(demo(), compression=c),
    )
  }
}

///|
test "reading something else is an error" {
  for
    junk in [
      b"",
      b"plain text",
      b"\x28\xb5\x2f\xfd\x00",
      Bytes::make(600, b'\x00'),
    ] {
    assert_true(
      try @arch.read(junk) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}
