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
  let mut high = -1
  for c in text {
    if c == '\n' || c == ' ' {
      continue
    }
    if high < 0 {
      high = hex_digit(c)
    } else {
      out.push((high * 16 + hex_digit(c)).to_byte())
      high = -1
    }
  }
  Bytes::from_array(out)
}

///|
fn sample_spec() -> @spec.PackageSpec raise {
  @spec.PackageSpec::new(
    name="hello",
    version="1.2.3",
    release="4",
    arch=@spec.Arch::Amd64,
    maintainer="Jane Doe <jane@example.org>",
    description="Says hello\nA longer text.",
    homepage="https://example.org/hello",
    license="Apache-2.0",
    depends=[
      @spec.Dependency::parse("musl >= 1.2"),
      @spec.Dependency::parse("bash"),
    ],
    recommends=[@spec.Dependency::parse("less")],
    conflicts=[@spec.Dependency::parse("hello-old < 1.0")],
    replaces=[@spec.Dependency::parse("hello-old")],
    provides=[@spec.Dependency::parse("greeter = 1.2")],
    entries=[
      @spec.Entry::file("/usr/bin/hello", b"#!/bin/sh\necho hi\n", mode=0o755),
      @spec.Entry::symlink("/usr/bin/hi", "hello"),
      @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
      @spec.Entry::dir("/var/lib/hello", mode=0o750),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\necho installed > /var/lib/hello/state\n"),
      pre_remove: Some("#!/bin/sh\nexit 0\n"),
      post_remove: Some("#!/bin/sh\nrm -f /var/lib/hello/state\n"),
    },
    mtime=1700000000L,
  )
}

///|
test "a package written by the real abuild is read and verified" {
  let data = decode_hex(real_tree_package)
  let pkg = @apk.read(data)
  assert_eq(pkg.signatures, [
    ".SIGN.RSA.alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub",
  ])
  assert_eq(pkg.field("pkgname"), Some("tree"))
  assert_eq(pkg.field("arch"), Some("x86_64"))
  assert_eq(pkg.field("pkgver"), Some("2.1.1-r0"))
  assert_eq(pkg.fields("depend"), ["so:libc.musl-x86_64.so.1"])
  assert_eq(pkg.data.map(i => i.0.path), ["usr/", "usr/bin/", "usr/bin/tree"])
  assert_eq(pkg.verify(), [])
  // datahash and the SHA-1 of the one file.
  assert_eq(pkg.checked_files(), 2)
  guard pkg.to_json() is Object(map) else { fail("object expected") }
  assert_eq(map["format"], Json::string("apk"))
  assert_eq(map["version"], Json::string("2.1.1"))
  assert_eq(map["release"], Json::string("0"))
  assert_eq(map["origin"], Json::string("tree"))
}

///|
test "a damaged real package is detected" {
  let data = decode_hex(real_tree_package)
  // A flipped byte in the data stream: the stream no longer unpacks cleanly
  // or its hash differs.
  let copy = data.to_fixedarray()
  copy[copy.length() / 2] = (copy[copy.length() / 2].to_int() ^ 1).to_byte()
  let problems = @apk.read(Bytes::from_array(copy[:])).verify() catch {
    _ => ["unreadable"]
  }
  assert_true(problems.length() > 0)
}

///|
test "building and reading back" {
  let spec = sample_spec()
  let data = @apk.build(spec)
  let pkg = @apk.read(data)
  assert_eq(pkg.signatures, [])
  assert_eq(pkg.verify(), [])
  assert_eq(@apk.file_name(spec), "hello-1.2.3-r4.apk")
  // .PKGINFO, exactly (the datahash is checked separately).
  let lines = pkg.pkginfo
    .filter(p => p.0 != "datahash")
    .map(p => "\{p.0} = \{p.1}")
  inspect(
    lines.join("\n"),
    content=(
      #|pkgname = hello
      #|pkgver = 1.2.3-r4
      #|pkgdesc = Says hello
      #|url = https://example.org/hello
      #|builddate = 1700000000
      #|packager = Jane Doe <jane@example.org>
      #|size = 22
      #|arch = x86_64
      #|origin = hello
      #|license = Apache-2.0
      #|replaces = hello-old
      #|provides = greeter=1.2
      #|depend = musl>=1.2
      #|depend = bash
      #|depend = !hello-old<1.0
    ),
  )
  assert_eq(pkg.data.map(i => i.0.path), [
    "etc/", "etc/hello.conf", "usr/", "usr/bin/", "usr/bin/hello", "usr/bin/hi",
    "var/", "var/lib/", "var/lib/hello/",
  ])
  // Control files: the scripts, executable, and the upgrade copies.
  assert_eq(pkg.control_files.map(f => f.0), [
    ".post-deinstall", ".post-install", ".post-upgrade", ".pre-deinstall",
  ])
  // datahash is the SHA-256 of the stored data stream.
  assert_eq(
    pkg.field("datahash"),
    Some(@crypto.bytes_to_hex_string(@crypto.sha256(pkg.data_packed))),
  )
  // SHA-1 records for the two regular files and the symbolic link.
  let sums = pkg.data.filter(i => i.1.length() > 0)
  assert_eq(sums.length(), 3)
  assert_eq(pkg.checked_files(), 4)
}

///|
test "output is deterministic and the control stream has no end marker" {
  let spec = sample_spec()
  assert_eq(@apk.build(spec), @apk.build(spec))
  let members = @compress.gzip_members(@apk.build(spec))
  assert_eq(members.length(), 2)
  // The control tar ends right after its last entry's padding.
  assert_eq(members[0].1.length() % 512, 0)
  assert_true(
    members[0].1[members[0].1.length() - 512:] != Bytes::make(512, b'\x00')[:],
  )
  // The data tar ends with two zero blocks.
  let data_tar = members[1].1
  assert_eq(
    data_tar[data_tar.length() - 1024:].to_owned(),
    Bytes::make(1024, b'\x00'),
  )
}

///|
test "the JSON report" {
  let pkg = @apk.read(@apk.build(sample_spec()))
  guard pkg.to_json() is Object(map) else { fail("object expected") }
  assert_eq(map["name"], Json::string("hello"))
  assert_eq(map["version"], Json::string("1.2.3"))
  assert_eq(map["release"], Json::string("4"))
  assert_eq(map["architecture"], Json::string("x86_64"))
  assert_eq(
    map["depends"],
    Json::array([Json::string("musl>=1.2"), Json::string("bash")]),
  )
  assert_eq(map["conflicts"], Json::array([Json::string("hello-old<1.0")]))
  assert_eq(
    map["compression"],
    Json::object({ "payload": Json::string("gzip") }),
  )
  guard map["scripts"] is Array(scripts) else { fail("scripts expected") }
  assert_eq(scripts.length(), 4)
}

///|
test "input that cannot be an Alpine package is refused" {
  let spec = sample_spec()
  let cases : Array[(@spec.PackageSpec, String)] = [
    ({ ..spec, arch: Armel, }, "arch: Alpine Linux has no port for armel"),
    ({ ..spec, epoch: 1, }, "epoch: apk packages have no epoch"),
    (
      { ..spec, release: "1a", },
      "release: must be a number for an apk package (it becomes -r<number>)",
    ),
    (
      { ..spec, version: "1.0~foo", },
      "version: \"1.0~foo\" is not an apk version (digits and dots, an optional letter, suffixes such as _rc1)",
    ),
    (
      {
        ..spec,
        scripts: { ..spec.scripts, post_install: Some("echo no shebang"), },
      },
      "scripts.post_install: must start with #! (a shebang line)",
    ),
  ]
  for item in cases {
    try @apk.build(item.0) catch {
      err => assert_eq("\{err}", item.1)
    } noraise {
      _ => fail("expected an error: \{item.1}")
    }
  }
  try @apk.build({ ..spec, name: "X", }) catch {
    @apk.ApkError::Invalid(field~, ..) => assert_eq(field, "name")
    err => fail("unexpected \{err}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "apk versions" {
  let valid = [
    ("1", "1"),
    ("1.2.3", "1.2.3"),
    ("2.0b", "2.0b"),
    ("1.0~rc1", "1.0_rc1"),
    ("1.0~p2", "1.0_p2"),
    ("3.1.4~alpha~p1", "3.1.4_alpha_p1"),
    ("10.0.0", "10.0.0"),
  ]
  for pair in valid {
    let spec = { ..sample_spec(), version: pair.0, }
    let pkg = @apk.read(@apk.build(spec))
    assert_eq(pkg.field("pkgver"), Some("\{pair.1}-r4"))
    assert_eq(@apk.file_name(spec), "hello-\{pair.1}-r4.apk")
  }
  for
    version in [
      "a", "1..2", "1.0~foo", "1.0~rc1x", "1.0+git", "1.0ab", "1.0~", "9.0.a.1",
    ] {
    try @apk.build({ ..sample_spec(), version, }) catch {
      _ => ()
    } noraise {
      _ => fail("\"\{version}\" should be refused")
    }
  }
}

///|
test "architectures" {
  assert_eq(@apk.arch_name(Amd64), Some("x86_64"))
  assert_eq(@apk.arch_name(Arm64), Some("aarch64"))
  assert_eq(@apk.arch_name(I386), Some("x86"))
  assert_eq(@apk.arch_name(Armhf), Some("armv7"))
  assert_eq(@apk.arch_name(All), Some("noarch"))
  assert_eq(@apk.arch_name(Mips64le), None)
  let pkg = @apk.read(@apk.build({ ..sample_spec(), arch: All, }))
  assert_eq(pkg.field("arch"), Some("noarch"))
}

///|
fn rebuild(
  data : Bytes,
  change : (Array[(@tar.Entry, Array[(String, String)])]) -> Array[
    (@tar.Entry, Array[(String, String)]),
  ],
) -> Bytes raise {
  let members = @compress.gzip_members(data)
  let items = @tar.parse_with_records(members[1].1)
  let tar = @tar.build_with_records(change(items))
  Bytes::from_array([..members[0].0, ..@compress.compress(tar, Gzip)])
}

///|
test "verify finds tampering" {
  let data = @apk.build(sample_spec())
  // Anything that changes the data stream breaks datahash.
  let changed = rebuild(data, items => items)
  let problems = @apk.read(changed).verify()
  assert_eq(problems.length(), 0) // same content, same bytes: still fine
  let edited = rebuild(data, items => {
    items.map(item => {
      match item.0.kind {
        File(_) if item.0.path == "usr/bin/hello" =>
          ({ ..item.0, kind: File(b"#!/bin/sh\nevil\n"), }, item.1)
        _ => item
      }
    })
  })
  let found = @apk.read(edited).verify()
  assert_eq(found.length(), 2)
  assert_true(found[0].has_prefix("datahash mismatch"))
  assert_true(found[1].has_prefix("usr/bin/hello: sha1 mismatch"))
  // An unsafe path and a duplicate.
  let unsafe_ = rebuild(data, items => {
    [..items, (@tar.Entry::file("../x", b"x"), []), items[0]]
  })
  let more = @apk.read(unsafe_).verify()
  assert_true(more.any(p => p == "../x: unsafe path"))
  assert_true(more.any(p => p.contains("appears twice")))
}

///|
test "reading refuses what is not an Alpine package" {
  let error_of = (data : Bytes) => {
    try @apk.read(data) catch {
      err => "\{err}"
    } noraise {
      _ => "ok"
    }
  }
  inspect(error_of(b""), content="corrupt apk: gzip: input too short")
  assert_true(error_of(b"not gzip at all").has_prefix("corrupt apk: gzip"))
  // One stream only.
  let one = @compress.compress(
    @tar.build([@tar.Entry::file(".PKGINFO", b"pkgname = a\n")]),
    Gzip,
  )
  assert_true(error_of(one).contains("found 1 gzip stream"))
  // No .PKGINFO in the control stream.
  let tar = @tar.build([@tar.Entry::file("a", b"x")])
  let two = Bytes::from_array(
    [..@compress.compress(tar, Gzip), ..@compress.compress(tar, Gzip)],
  )
  inspect(
    error_of(two),
    content="corrupt apk: the control segment has no .PKGINFO, this is not an Alpine Linux package",
  )
  // An archive from another format.
  assert_true(
    error_of(@compress.compress(b"!<arch>\n", Xz)).has_prefix("corrupt apk"),
  )
}

///|
test "a bomb is stopped" {
  let bomb = @compress.compress(Bytes::make(4 * 1024 * 1024, b'\x00'), Gzip)
  try
    @apk.read(Bytes::from_array([..bomb, ..bomb]), max_unpacked=1024 * 1024)
  catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt apk: the package unpacks to more than 1048576 bytes",
      )
  } noraise {
    _ => fail("expected the limit to be hit")
  }
}

///|
test "every truncation and flipped byte is handled" {
  let survives = (data : BytesView) => {
    try {
      let pkg = @apk.read(data)
      ignore(pkg.verify())
      ignore(pkg.to_json().stringify())
    } catch {
      _ => ()
    }
  }
  let data = @apk.build(sample_spec())
  let step = data.length() / 300 + 1
  let mut at = 0
  while at < data.length() {
    survives(data[0:at])
    let copy = data.to_fixedarray()
    copy[at] = (copy[at].to_int() ^ 0xff).to_byte()
    survives(Bytes::from_array(copy[:]))
    at += step
  }
}
