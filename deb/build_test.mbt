///|
fn sample_spec() -> @spec.PackageSpec raise {
  @spec.PackageSpec::new(
    name="hello",
    version="1.0.0",
    release="2",
    epoch=1,
    arch=@spec.Arch::Amd64,
    maintainer="Jane Doe <jane@example.org>",
    description="Says hello\nThis program prints a friendly greeting.\n\nIt is only an example.",
    homepage="https://example.org/hello",
    section="utils",
    priority="optional",
    depends=[
      @spec.Dependency::parse("libc6 (>= 2.31)"),
      @spec.Dependency::parse("bash"),
    ],
    conflicts=[@spec.Dependency::parse("hello-old (<< 1.0)")],
    provides=[@spec.Dependency::parse("greeter")],
    entries=[
      @spec.Entry::file("/usr/bin/hello", b"#!/bin/sh\necho hi\n", mode=0o755),
      @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
      @spec.Entry::symlink("/usr/bin/hi", "hello"),
      @spec.Entry::dir("/var/lib/hello", mode=0o700),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\nexit 0\n"),
      pre_remove: None,
      post_remove: None,
    },
    mtime=1700000000L,
  )
}

///|
test "control file fields and description formatting" {
  inspect(
    @deb.control_file(sample_spec()),
    content=(
      #|Package: hello
      #|Version: 1:1.0.0-2
      #|Architecture: amd64
      #|Maintainer: Jane Doe <jane@example.org>
      #|Installed-Size: 1
      #|Depends: libc6 (>= 2.31), bash
      #|Conflicts: hello-old (<< 1.0)
      #|Provides: greeter
      #|Section: utils
      #|Priority: optional
      #|Homepage: https://example.org/hello
      #|Description: Says hello
      #| This program prints a friendly greeting.
      #| .
      #| It is only an example.
      #|
    ),
  )
}

///|
test "file name and version string" {
  assert_eq(@deb.version_string(sample_spec()), "1:1.0.0-2")
  assert_eq(@deb.file_name(sample_spec()), "hello_1.0.0-2_amd64.deb")
  let all = { ..sample_spec(), arch: @spec.Arch::All, epoch: 0, }
  assert_eq(@deb.version_string(all), "1.0.0-2")
  assert_eq(@deb.file_name(all), "hello_1.0.0-2_all.deb")
}

///|
/// Open a built deb: the ar members by name, with the tar members
/// decompressed.
fn open_deb(deb : Bytes) -> (@ar.Member, Bytes, Bytes) raise {
  let members = @ar.parse(deb)
  assert_eq(members.map(m => m.name), [
    "debian-binary", "control.tar.gz", "data.tar.gz",
  ])
  (
    members[0],
    @compress.decompress(members[1].data, Gzip),
    @compress.decompress(members[2].data, Gzip),
  )
}

///|
test "a deb is debian-binary plus control and data archives" {
  let (version, control, data) = open_deb(@deb.build(sample_spec()))
  assert_eq(version.data, b"2.0\n")
  assert_eq(version.mtime, 1700000000L)
  assert_eq(version.mode, 0o100644)
  let mtime = 1700000000L
  let script = @utf8.encode("#!/bin/sh\nexit 0\n")
  let expected_control = @tar.build([
    @tar.Entry::dir("./", mtime~),
    @tar.Entry::file("./conffiles", b"/etc/hello.conf\n", mtime~),
    @tar.Entry::file(
      "./control",
      @utf8.encode(@deb.control_file(sample_spec())),
      mtime~,
    ),
    @tar.Entry::file(
      "./md5sums",
      b"f968f33f844c98de1d3b4fe70f2e1a0f  etc/hello.conf\n46bbbe8aa98cc0714426e948474eaaf4  usr/bin/hello\n",
      mtime~,
    ),
    @tar.Entry::file("./postinst", script, mode=0o755, mtime~),
  ])
  inspect(diff_bytes(control, expected_control), content="same")
  let expected_data = @tar.build([
    @tar.Entry::dir("./", mtime~),
    @tar.Entry::dir("./etc", mtime~),
    @tar.Entry::file("./etc/hello.conf", b"x=1\n", mtime~),
    @tar.Entry::dir("./usr", mtime~),
    @tar.Entry::dir("./usr/bin", mtime~),
    @tar.Entry::file(
      "./usr/bin/hello",
      b"#!/bin/sh\necho hi\n",
      mode=0o755,
      mtime~,
    ),
    @tar.Entry::symlink("./usr/bin/hi", "hello", mtime~),
    @tar.Entry::dir("./var", mtime~),
    @tar.Entry::dir("./var/lib", mtime~),
    @tar.Entry::dir("./var/lib/hello", mode=0o700, mtime~),
  ])
  inspect(diff_bytes(data, expected_data), content="same")
}

///|
test "entries keep their owner and per-entry mtime" {
  let spec = {
    ..@spec.PackageSpec::new(
      name="owned",
      version="1.0",
      arch=@spec.Arch::All,
      maintainer="Jane <jane@example.org>",
      description="Owned files",
      mtime=100L,
      entries=[
        @spec.Entry::file(
          "/srv/app/data",
          b"d",
          owner="www-data",
          group="adm",
          mtime=200L,
        ),
      ],
    ),
  }
  let (_, _, data) = open_deb(@deb.build(spec))
  let expected = @tar.build([
    @tar.Entry::dir("./", mtime=100L),
    @tar.Entry::dir("./srv", mtime=100L),
    @tar.Entry::dir("./srv/app", mtime=100L),
    @tar.Entry::file(
      "./srv/app/data",
      b"d",
      uname="www-data",
      gname="adm",
      mtime=200L,
    ),
  ])
  inspect(diff_bytes(data, expected), content="same")
}

///|
test "explicit directories replace the implicit ones" {
  let spec = @spec.PackageSpec::new(
    name="dirs",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Dirs",
    entries=[
      @spec.Entry::file("/opt/tool/bin", b"b"),
      @spec.Entry::dir("/opt/tool", mode=0o750, owner="app", group="app"),
    ],
  )
  let (_, _, data) = open_deb(@deb.build(spec))
  let expected = @tar.build([
    @tar.Entry::dir("./"),
    @tar.Entry::dir("./opt"),
    @tar.Entry::dir("./opt/tool", mode=0o750, uname="app", gname="app"),
    @tar.Entry::file("./opt/tool/bin", b"b"),
  ])
  inspect(diff_bytes(data, expected), content="same")
}

///|
test "sorting follows byte order of the full path" {
  // "bin-extra" sorts before "bin/x" because '-' is smaller than '/'.
  let spec = @spec.PackageSpec::new(
    name="order",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Order",
    entries=[
      @spec.Entry::file("/usr/bin/x", b"1"),
      @spec.Entry::file("/usr/bin-extra", b"2"),
      @spec.Entry::file("/usr/Bin", b"3"),
    ],
  )
  let (_, _, data) = open_deb(@deb.build(spec))
  let expected = @tar.build([
    @tar.Entry::dir("./"),
    @tar.Entry::dir("./usr"),
    @tar.Entry::file("./usr/Bin", b"3"),
    @tar.Entry::dir("./usr/bin"),
    @tar.Entry::file("./usr/bin-extra", b"2"),
    @tar.Entry::file("./usr/bin/x", b"1"),
  ])
  inspect(diff_bytes(data, expected), content="same")
}

///|
test "a package without files still has the root directory and no md5sums" {
  let spec = @spec.PackageSpec::new(
    name="meta",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Metapackage",
  )
  let (_, control, data) = open_deb(@deb.build(spec))
  assert_eq(data, @tar.build([@tar.Entry::dir("./")]))
  assert_eq(
    control,
    @tar.build([
      @tar.Entry::dir("./"),
      @tar.Entry::file("./control", @utf8.encode(@deb.control_file(spec))),
    ]),
  )
}

///|
test "building twice gives identical bytes" {
  assert_eq(@deb.build(sample_spec()), @deb.build(sample_spec()))
}

///|
fn build_error(spec : @spec.PackageSpec) -> String {
  try @deb.build(spec) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "invalid specs are reported with their field" {
  inspect(
    build_error({ ..sample_spec(), name: "Hello", }),
    content="name: must be lowercase",
  )
  inspect(
    build_error({
      ..sample_spec(),
      entries: [@spec.Entry::file("usr/bin/x", b"")],
    }),
    content="entries[0].path: must be an absolute path starting with '/'",
  )
}

///|
test "maintainer scripts need an interpreter line" {
  let spec = {
    ..sample_spec(),
    scripts: {
      pre_install: None,
      post_install: None,
      pre_remove: Some("echo bye\n"),
      post_remove: None,
    },
  }
  inspect(
    build_error(spec),
    content="scripts.pre_remove: must start with a #! line naming its interpreter",
  )
}

///|
/// Describe how two byte strings differ, so a failing comparison of large
/// archives stays readable.
fn diff_bytes(actual : Bytes, expected : Bytes) -> String {
  if actual == expected {
    return "same"
  }
  let limit = if actual.length() < expected.length() {
    actual.length()
  } else {
    expected.length()
  }
  let mut at = limit
  for i in 0..<limit {
    if actual[i] != expected[i] {
      at = i
      break
    }
  }
  let start = if at >= 16 { at - 16 } else { 0 }
  let end_a = if at + 48 < actual.length() { at + 48 } else { actual.length() }
  let end_e = if at + 48 < expected.length() {
    at + 48
  } else {
    expected.length()
  }
  "lengths \{actual.length()} vs \{expected.length()}, first difference at \{at} (block \{at / 512}, offset \{at % 512})\n actual: \{@utf8.decode_lossy(actual[start:end_a])}\n expected: \{@utf8.decode_lossy(expected[start:end_e])}"
}

///|
test "paths too long for ustar use GNU long names so that dpkg can unpack them" {
  let long = "/opt/" + "a".repeat(140) + "/" + "b".repeat(140) + "/f"
  let spec = @spec.PackageSpec::new(
    name="longname",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Long names",
    entries=[@spec.Entry::file(long, b"long\n")],
  )
  let (_, _, data) = open_deb(@deb.build(spec))
  let expected = @tar.build(
    [
      @tar.Entry::dir("./"),
      @tar.Entry::dir("./opt"),
      @tar.Entry::dir("./opt/" + "a".repeat(140)),
      @tar.Entry::dir("./opt/" + "a".repeat(140) + "/" + "b".repeat(140)),
      @tar.Entry::file("." + long, b"long\n"),
    ],
    long_names=Gnu,
  )
  inspect(diff_bytes(data, expected), content="same")
  // The long file name is stored in an L entry, never in a PAX header.
  let mut has_pax = false
  for i = 0; i + 512 <= data.length(); i = i + 512 {
    if data[i + 156] == b'x' {
      has_pax = true
    }
  }
  assert_eq(has_pax, false)
}

///|
test "every compression yields a deb that reads back and verifies" {
  let spec = sample_spec()
  let kinds : Array[(@compress.Compression, String)] = [
    (Gzip, ".gz"),
    (Xz, ".xz"),
    (Zstd, ".zst"),
    (None, ""),
  ]
  for pair in kinds {
    let deb = @deb.build(spec, compression=pair.0)
    let members = @ar.parse(deb)
    assert_eq(members.map(m => m.name), [
      "debian-binary",
      "control.tar" + pair.1,
      "data.tar" + pair.1,
    ])
    let pkg = @deb.read(deb)
    assert_eq(pkg.control_compression, pair.0.name())
    assert_eq(pkg.data_compression, pair.0.name())
    assert_eq(pkg.field("Package"), Some("hello"))
    assert_eq(pkg.verify(), [])
    // Same input, same bytes.
    assert_eq(deb, @deb.build(spec, compression=pair.0))
  }
  // The default is gzip.
  assert_eq(@deb.build(spec), @deb.build(spec, compression=Gzip))
}

///|
test "lzma cannot be chosen for writing" {
  try @deb.build(sample_spec(), compression=Lzma) catch {
    @deb.DebError::Invalid(field~, ..) => assert_eq(field, "compression")
    err => fail("unexpected \{err}")
  } noraise {
    _ => fail("expected an error")
  }
}
