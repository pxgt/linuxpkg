///|
fn hex_digit(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    _ => abort("bad hex digit in fixture")
  }
}

///|
fn decode_hex(text : String) -> Bytes {
  let out : Array[Byte] = []
  let chars : Array[Char] = []
  for c in text {
    if c != '\n' && c != ' ' {
      chars.push(c)
    }
  }
  for i = 0; i < chars.length(); i = i + 2 {
    out.push((hex_digit(chars[i]) * 16 + hex_digit(chars[i + 1])).to_byte())
  }
  Bytes::from_array(out[:])
}

///|
fn read_error(deb : BytesView) -> String {
  try {
    ignore(@deb.read(deb))
    "ok"
  } catch {
    err => "\{err}"
  }
}

///|
test "a deb written by the real dpkg-deb is understood" {
  let pkg = @deb.read(decode_hex(real_gzip_deb))
  assert_eq(pkg.format_version, "2.0")
  assert_eq(pkg.control_compression, "gzip")
  assert_eq(pkg.data_compression, "gzip")
  assert_eq(pkg.field("package"), Some("realdeb"))
  assert_eq(pkg.field("Version"), Some("2.5-3"))
  assert_eq(pkg.field("Architecture"), Some("all"))
  assert_eq(pkg.field("Depends"), Some("bash (>= 4.0), coreutils"))
  assert_eq(pkg.field("Homepage"), Some("https://example.org/realdeb"))
  assert_eq(
    pkg.field("Description"),
    Some(
      "A package built by dpkg-deb\nSecond line of the description.\n\nAfter a blank line.",
    ),
  )
  assert_eq(pkg.field("Replaces"), None)
  assert_eq(pkg.conffiles, ["/etc/realdeb.conf"])
  assert_eq(pkg.md5sums.map(s => s.0), [
    "/etc/realdeb.conf", "/usr/share/realdeb/data.txt",
  ])
  assert_eq(pkg.files.map(e => @deb.normalize_path(e.path)), [
    "/", "/etc", "/etc/realdeb.conf", "/usr", "/usr/share", "/usr/share/realdeb",
    "/usr/share/realdeb/data.txt", "/usr/share/realdeb/link",
  ])
  assert_eq(pkg.files[6].kind, @tar.EntryKind::File(b"hello from dpkg-deb\n"))
  assert_eq(pkg.files[7].kind, @tar.EntryKind::Symlink("data.txt"))
  assert_eq(pkg.files[6].uname, "root")
  assert_eq(pkg.files[6].mtime, 1700000000L)
  assert_eq(pkg.control_files.map(f => f.0), [
    "conffiles", "control", "md5sums", "postinst",
  ])
  assert_eq(pkg.verify(), [])
}

///|
test "the JSON report of a real deb" {
  let pkg = @deb.read(decode_hex(real_gzip_deb))
  let report = pkg.to_json()
  guard report is Object(map) else { fail("report must be an object") }
  assert_eq(map["format"], Json::string("deb"))
  assert_eq(map["name"], Json::string("realdeb"))
  assert_eq(map["version"], Json::string("2.5-3"))
  assert_eq(map["architecture"], Json::string("all"))
  assert_eq(map["summary"], Json::string("A package built by dpkg-deb"))
  assert_eq(
    map["depends"],
    Json::array([Json::string("bash (>= 4.0)"), Json::string("coreutils")]),
  )
  assert_eq(map["conffiles"], Json::array([Json::string("/etc/realdeb.conf")]))
  assert_eq(map["scripts"], Json::array([Json::string("postinst")]))
  assert_eq(map["license"], Json::null())
  json_inspect(map["files"], content=[
    {
      "path": "/",
      "type": "dir",
      "mode": "0755",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/etc",
      "type": "dir",
      "mode": "0755",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/etc/realdeb.conf",
      "type": "file",
      "mode": "0644",
      "owner": "root",
      "group": "root",
      "size": 10,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/usr",
      "type": "dir",
      "mode": "0755",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/usr/share",
      "type": "dir",
      "mode": "0755",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/usr/share/realdeb",
      "type": "dir",
      "mode": "0755",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/usr/share/realdeb/data.txt",
      "type": "file",
      "mode": "0644",
      "owner": "root",
      "group": "root",
      "size": 20,
      "mtime": 1700000000,
      "link": null,
      "elf": null,
    },
    {
      "path": "/usr/share/realdeb/link",
      "type": "symlink",
      "mode": "0777",
      "owner": "root",
      "group": "root",
      "size": 0,
      "mtime": 1700000000,
      "link": "data.txt",
      "elf": null,
    },
  ])
}

///|
test "debs written by dpkg-deb with xz and zstd members are read and verified" {
  for pair in [(real_xz_deb, "xz"), (real_zstd_deb, "zstd")] {
    let pkg = @deb.read(decode_hex(pair.0))
    assert_eq(pkg.control_compression, pair.1)
    assert_eq(pkg.data_compression, pair.1)
    assert_eq(pkg.field("Package"), Some("realdeb"))
    assert_eq(pkg.field("Version"), Some("2.5-3"))
    assert_eq(pkg.files.length(), 8)
    assert_eq(pkg.conffiles, ["/etc/realdeb.conf"])
    assert_eq(pkg.verify(), [])
  }
}

///|
fn sample_package() -> @spec.PackageSpec raise {
  @spec.PackageSpec::new(
    name="sample",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Sample\nWith a body.",
    depends=[@spec.Dependency::parse("bash (>= 4.0)")],
    entries=[
      @spec.Entry::file("/usr/bin/sample", b"#!/bin/sh\n", mode=0o755),
      @spec.Entry::file("/etc/sample.conf", b"a=1\n", config=true),
      @spec.Entry::symlink("/usr/bin/s", "sample"),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\nexit 0\n"),
      pre_remove: Some("#!/bin/sh\nexit 0\n"),
      post_remove: None,
    },
    mtime=1700000000L,
  )
}

///|
test "reading what we build" {
  let pkg = @deb.read(@deb.build(sample_package()))
  assert_eq(pkg.field("Package"), Some("sample"))
  assert_eq(pkg.field("Depends"), Some("bash (>= 4.0)"))
  assert_eq(pkg.field("Description"), Some("Sample\nWith a body."))
  assert_eq(pkg.conffiles, ["/etc/sample.conf"])
  assert_eq(pkg.control_files.map(f => f.0), [
    "conffiles", "control", "md5sums", "postinst", "prerm",
  ])
  assert_eq(pkg.files.map(e => @deb.normalize_path(e.path)), [
    "/", "/etc", "/etc/sample.conf", "/usr", "/usr/bin", "/usr/bin/s", "/usr/bin/sample",
  ])
  assert_eq(pkg.verify(), [])
}

///|
test "verify finds tampered content and bad metadata" {
  let pkg = @deb.read(@deb.build(sample_package()))
  // Replace the content of one file without updating md5sums.
  let tampered = pkg.files.map(e => {
    match e.kind {
      File(_) if e.path == "./usr/bin/sample" =>
        { ..e, kind: @tar.EntryKind::File(b"#!/bin/sh\nrm -rf /\n"), }
      _ => e
    }
  })
  let problems = { ..pkg, files: tampered, }.verify()
  assert_eq(problems.length(), 1)
  assert_true(
    problems[0].has_prefix("/usr/bin/sample: md5 mismatch (md5sums says "),
  )
  // A missing file, a stray conffile and bad paths.
  let broken = {
    ..pkg,
    fields: [("Package", "sample")],
    files: [
      @tar.Entry::file("./usr/bin/sample", b"#!/bin/sh\n"),
      @tar.Entry::file("./usr/bin/sample", b"#!/bin/sh\n"),
      @tar.Entry::file("./usr/../etc/shadow", b"x"),
    ],
    conffiles: ["/etc/gone.conf"],
    md5sums: [("/usr/share/missing", "00000000000000000000000000000000")],
  }
  assert_eq(broken.verify(), [
    "control: missing required field \"Version\"", "control: missing required field \"Architecture\"",
    "control: missing required field \"Maintainer\"", "control: missing required field \"Description\"",
    "/usr/bin/sample: appears more than once in data.tar", "./usr/../etc/shadow: path escapes the installation root",
    "/usr/share/missing: listed in md5sums but is not a file of the package", "/etc/gone.conf: listed in conffiles but is not in the package",
  ])
}

///|
fn ar_with(members : Array[(String, Bytes)]) -> Bytes raise {
  @ar.build(members.map(m => @ar.Member::new(m.0, m.1)))
}

///|
test "uncompressed members are accepted" {
  let built = @ar.parse(@deb.build(sample_package()))
  let control = @compress.decompress(built[1].data, Gzip)
  let data = @compress.decompress(built[2].data, Gzip)
  let plain = ar_with([
    ("debian-binary", b"2.0\n"),
    ("control.tar", control),
    ("data.tar", data),
  ])
  let pkg = @deb.read(plain)
  assert_eq(pkg.control_compression, "none")
  assert_eq(pkg.data_compression, "none")
  assert_eq(pkg.verify(), [])
}

///|
test "structural problems" {
  inspect(
    read_error(b"not an archive"),
    content="corrupt deb: ar offset 0: missing \"!<arch>\" signature",
  )
  inspect(
    read_error(ar_with([("hello.txt", b"hi")])),
    content="corrupt deb: the first ar member must be debian-binary, this is not a deb",
  )
  inspect(
    read_error(ar_with([("debian-binary", b"3.0\n")])),
    content="unsupported deb: deb format version \"3.0\" (only 2.x is supported)",
  )
  inspect(
    read_error(ar_with([("debian-binary", b"2.0\n")])),
    content="corrupt deb: control.tar member is missing",
  )
  inspect(
    read_error(ar_with([("debian-binary", b"2.0\n"), ("control.tar.gz", b"")])),
    content="corrupt deb: data.tar member is missing",
  )
  inspect(
    read_error(
      ar_with([
        ("debian-binary", b"2.0\n"),
        ("control.tar.zst", b""),
        ("data.tar.zst", b""),
      ]),
    ),
    content="corrupt deb: control.tar.zst: zstd: input too short",
  )
  inspect(
    read_error(
      ar_with([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", b"\x00\x01\x02"),
        ("data.tar.gz", b""),
      ]),
    ),
    content="corrupt deb: control.tar.gz: gzip: truncated",
  )
}

///|
test "a control.tar without a control file" {
  let control = @tar.build([@tar.Entry::file("./md5sums", b"")])
  let deb = ar_with([
    ("debian-binary", b"2.0\n"),
    ("control.tar", control),
    ("data.tar", @tar.build([])),
  ])
  inspect(
    read_error(deb),
    content="corrupt deb: control.tar has no control file",
  )
}

///|
test "damaged gzip streams are detected by their CRC" {
  let deb = @deb.build(sample_package())
  let members = @ar.parse(deb)
  let damaged = Bytes::from_array(
    members[2].data
    .to_array()
    .mapi((i, b) => {
      if i == members[2].data.length() - 12 {
        (b.to_int() ^ 0xff).to_byte()
      } else {
        b
      }
    }),
  )
  let rebuilt = @ar.build([
    members[0],
    members[1],
    @ar.Member::new("data.tar.gz", damaged),
  ])
  assert_true(read_error(rebuilt).has_prefix("corrupt deb: data.tar.gz: "))
}

///|
test "unpacked size is bounded" {
  let deb = @deb.build(sample_package())
  try @deb.read(deb, max_unpacked=100) catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt deb: control.tar.gz unpacks to more than 100 bytes",
      )
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "control file parsing" {
  let fields = @deb.parse_control(
    "Package: demo\nDescription: Title\n first\n .\n second\nDepends:  a ,  b\n\n",
  )
  assert_eq(fields, [
    ("Package", "demo"),
    ("Description", "Title\nfirst\n\nsecond"),
    ("Depends", "a ,  b"),
  ])
  assert_eq(@deb.parse_control(""), [])
  assert_eq(@deb.parse_control("# comment\nA: 1\n"), [("A", "1")])
  fn control_error(text : String) -> String {
    try @deb.parse_control(text) catch {
      err => "\{err}"
    } noraise {
      _ => "ok"
    }
  }

  inspect(
    control_error(" continuation first\n"),
    content="corrupt deb: control file starts with a continuation line",
  )
  inspect(
    control_error("no colon here\n"),
    content="corrupt deb: control line is not \"Field: value\": \"no colon here\"",
  )
  inspect(
    control_error("A: 1\n\nB: 2\n"),
    content="corrupt deb: control file has more than one paragraph",
  )
  inspect(
    control_error("bad name: 1\n"),
    content="corrupt deb: invalid control field name \"bad name\"",
  )
}

///|
test "md5sums parsing" {
  let sums = @deb.parse_md5sums(
    "d41d8cd98f00b204e9800998ecf8427e  usr/bin/a\nb1946ac92492d2347c6235b4d2611184 *etc/b c\n",
  )
  assert_eq(sums, [
    ("/usr/bin/a", "d41d8cd98f00b204e9800998ecf8427e"),
    ("/etc/b c", "b1946ac92492d2347c6235b4d2611184"),
  ])
  try @deb.parse_md5sums("short\n") catch {
    err => inspect("\{err}", content="corrupt deb: bad md5sums line: \"short\"")
  } noraise {
    _ => fail("expected an error")
  }
  try @deb.parse_md5sums("D41D8CD98F00B204E9800998ECF8427E  x\n") catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt deb: md5sums digest is not lowercase hexadecimal: \"D41D8CD98F00B204E9800998ECF8427E  x\"",
      )
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "path normalization" {
  assert_eq(@deb.normalize_path("./"), "/")
  assert_eq(@deb.normalize_path("."), "/")
  assert_eq(@deb.normalize_path("./usr/bin/"), "/usr/bin")
  assert_eq(@deb.normalize_path("usr/bin/x"), "/usr/bin/x")
  assert_eq(@deb.normalize_path("/usr/bin/x"), "/usr/bin/x")
  assert_eq(@deb.normalize_path("././usr"), "/usr")
}
