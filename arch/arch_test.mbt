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
    epoch=2,
    arch=@spec.Arch::Amd64,
    maintainer="Jane Doe <jane@example.org>",
    description="Says hello\nA longer text.",
    homepage="https://example.org/hello",
    license="Apache-2.0",
    depends=[
      @spec.Dependency::parse("glibc >= 2.31"),
      @spec.Dependency::parse("bash"),
    ],
    recommends=[@spec.Dependency::parse("less")],
    suggests=[@spec.Dependency::parse("man-db > 2")],
    conflicts=[@spec.Dependency::parse("hello-old < 1.0")],
    replaces=[@spec.Dependency::parse("hello-old")],
    provides=[@spec.Dependency::parse("greeter = 1.2")],
    entries=[
      @spec.Entry::file("/usr/bin/hello", b"#!/bin/sh\necho hi\n", mode=0o755),
      @spec.Entry::symlink("/usr/bin/hi", "hello"),
      @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
      @spec.Entry::dir("/var/lib/hello", mode=0o750),
      @spec.Entry::file("/usr/share/doc/hello/a b#c.txt", b"odd name\n"),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\necho installed > /var/lib/hello/state\n"),
      pre_remove: None,
      post_remove: Some("#!/bin/sh\nrm -f /var/lib/hello/state\n"),
    },
    mtime=1700000000L,
  )
}

///|
test "a package written by the real makepkg is read and verified" {
  let data = decode_hex(real_which_package)
  let pkg = @arch.read(data)
  assert_eq(pkg.compression, "zstd")
  assert_eq(pkg.field("pkgname"), Some("which"))
  assert_eq(pkg.field("arch"), Some("x86_64"))
  assert_eq(pkg.field("xdata"), Some("pkgtype=pkg"))
  assert_eq(pkg.fields("depend"), ["bash", "glibc"])
  assert_eq(pkg.verify(), [])
  assert_eq(pkg.checked_files(), 5)
  let report = pkg.to_json()
  guard report is Object(map) else { fail("object expected") }
  assert_eq(map["format"], Json::string("arch"))
  assert_eq(map["name"], Json::string("which"))
  assert_eq(map["architecture"], Json::string("x86_64"))
  assert_eq(
    map["depends"],
    Json::array([Json::string("bash"), Json::string("glibc")]),
  )
  guard map["files"] is Array(files) else { fail("files expected") }
  let paths = files.map(f => {
    match f {
      Object(entry) =>
        match entry["path"] {
          String(p) => p
          _ => ""
        }
      _ => ""
    }
  })
  assert_eq(paths[0], "/usr")
  assert_true(paths.contains("/usr/bin/which"))
  assert_true(!paths.contains("/.PKGINFO"))
  // The mtree of the real package lists the dot files, files and links.
  match pkg.mtree {
    Some(entries) => {
      assert_eq(entries[0].path, ".BUILDINFO")
      assert_true(entries.any(e => e.path == "usr/bin" && e.kind == "dir"))
    }
    None => fail("the package has an .MTREE")
  }
}

///|
test "a damaged real package is detected" {
  let data = decode_hex(real_which_package)
  // Unpack, change one byte of a file, pack again.
  let tar = @compress.decompress(data, Zstd)
  let entries = @tar.parse(tar)
  let changed = entries.map(e => {
    match e.kind {
      File(content) if e.path == "usr/bin/which" => {
        let copy = content.to_fixedarray()
        copy[100] = (copy[100].to_int() ^ 1).to_byte()
        { ..e, kind: File(Bytes::from_array(copy[:])), }
      }
      _ => e
    }
  })
  let damaged = @compress.compress(@tar.build(changed), Zstd)
  let problems = @arch.read(damaged).verify()
  assert_eq(problems.length(), 1)
  assert_true(problems[0].has_prefix("usr/bin/which: sha256 mismatch"))
}

///|
test "building and reading back" {
  let spec = sample_spec()
  let data = @arch.build(spec)
  let pkg = @arch.read(data)
  assert_eq(pkg.compression, "zstd")
  assert_eq(pkg.verify(), [])
  // .PKGINFO, exactly.
  inspect(
    pkg.pkginfo.map(p => "\{p.0} = \{p.1}").join("\n"),
    content=(
      #|pkgname = hello
      #|pkgbase = hello
      #|xdata = pkgtype=pkg
      #|pkgver = 2:1.2.3-4
      #|pkgdesc = Says hello
      #|url = https://example.org/hello
      #|builddate = 1700000000
      #|packager = Jane Doe <jane@example.org>
      #|size = 31
      #|arch = x86_64
      #|license = Apache-2.0
      #|replaces = hello-old
      #|conflict = hello-old<1.0
      #|provides = greeter=1.2
      #|backup = etc/hello.conf
      #|depend = glibc>=2.31
      #|depend = bash
      #|optdepend = less
      #|optdepend = man-db>2
    ),
  )
  // Entry order: metadata first, then the files sorted by path.
  assert_eq(pkg.entries.map(e => e.path), [
    ".INSTALL", ".MTREE", ".PKGINFO", "etc/", "etc/hello.conf", "usr/", "usr/bin/",
    "usr/bin/hello", "usr/bin/hi", "usr/share/", "usr/share/doc/", "usr/share/doc/hello/",
    "usr/share/doc/hello/a b#c.txt", "var/", "var/lib/", "var/lib/hello/",
  ])
  assert_eq(@arch.file_name(spec), "hello-2:1.2.3-4-x86_64.pkg.tar.zst")
  assert_eq(pkg.checked_files(), 5)
}

///|
test "the mtree text" {
  let pkg = @arch.read(@arch.build(sample_spec()))
  let mtree = pkg.mtree.unwrap()
  let by_path = Map(mtree.map(e => (e.path, e)))
  assert_eq(by_path["usr/bin/hello"].mode, Some(0o755))
  assert_eq(by_path["usr/bin/hello"].kind, "file")
  assert_eq(by_path["usr/bin/hello"].size, Some(18L))
  assert_eq(by_path["usr/bin/hi"].kind, "link")
  assert_eq(by_path["usr/bin/hi"].link, Some("hello"))
  assert_eq(by_path["var/lib/hello"].mode, Some(0o750))
  assert_eq(by_path["etc/hello.conf"].mode, Some(0o644))
  // Odd characters in a path are escaped and come back unchanged.
  assert_true(by_path.contains("usr/share/doc/hello/a b#c.txt"))
}

///|
test "mtree parsing: defaults, escapes and errors" {
  let text = "#mtree\n/set type=file uid=0 gid=0 mode=644\n./a time=1.0 size=3 sha256digest=AB\n/set mode=755\n./d time=1.0 type=dir\n/unset mode\n./e\\040f time=1.0 size=1\n./l type=link link=x\\040y mode=777\n..\n./\n"
  let entries = @arch.parse_mtree(text)
  assert_eq(entries.length(), 4)
  assert_eq(entries[0].path, "a")
  assert_eq(entries[0].mode, Some(0o644))
  assert_eq(entries[0].sha256, Some("ab"))
  assert_eq(entries[1].kind, "dir")
  assert_eq(entries[1].mode, Some(0o755))
  assert_eq(entries[2].path, "e f")
  assert_eq(entries[2].mode, None)
  assert_eq(entries[3].link, Some("x y"))
  let bad = [
    "/frobnicate\n", "./a type=socket\n", "./a mode=9\n", "./a size=x\n",
  ]
  for item in bad {
    try @arch.parse_mtree(item) catch {
      @arch.ArchError::Corrupt(..) => ()
      err => fail("unexpected \{err}")
    } noraise {
      _ => fail("expected an error for \{item}")
    }
  }
}

///|
test "every compression is written and read" {
  let spec = sample_spec()
  let kinds : Array[(@compress.Compression, String, String)] = [
    (Zstd, "zstd", ".zst"),
    (Xz, "xz", ".xz"),
    (Gzip, "gzip", ".gz"),
    (None, "none", ""),
  ]
  for kind in kinds {
    let data = @arch.build(spec, compression=kind.0)
    let pkg = @arch.read(data)
    assert_eq(pkg.compression, kind.1)
    assert_eq(pkg.verify(), [])
    assert_eq(
      @arch.file_name(spec, compression=kind.0),
      "hello-2:1.2.3-4-x86_64.pkg.tar\{kind.2}",
    )
    assert_eq(data, @arch.build(spec, compression=kind.0))
  }
}

///|
test ".INSTALL maps the maintainer scripts" {
  let pkg = @arch.read(@arch.build(sample_spec()))
  let install = pkg.install.unwrap()
  inspect(
    install,
    content=(
      #|# Generated by linuxpkg
      #|
      #|post_install() {
      #|  echo installed > /var/lib/hello/state
      #|  :
      #|}
      #|
      #|post_remove() {
      #|  rm -f /var/lib/hello/state
      #|  :
      #|}
      #|
      #|post_upgrade() {
      #|  post_install
      #|}
      #|
    ),
  )
  guard pkg.to_json() is Object(map) else { fail("object expected") }
  assert_eq(
    map["scripts"],
    Json::array([
      Json::string("post_install"),
      Json::string("post_remove"),
      Json::string("post_upgrade"),
    ]),
  )
  // Without scripts there is no .INSTALL.
  let plain = @arch.read(
    @arch.build({ ..sample_spec(), scripts: @spec.Scripts::empty(), }),
  )
  assert_eq(plain.install, None)
}

///|
test "the JSON report" {
  let pkg = @arch.read(@arch.build(sample_spec()))
  guard pkg.to_json() is Object(map) else { fail("object expected") }
  assert_eq(map["name"], Json::string("hello"))
  assert_eq(map["version"], Json::string("1.2.3"))
  assert_eq(map["release"], Json::string("4"))
  assert_eq(map["epoch"], Json::number(2.0))
  assert_eq(map["maintainer"], Json::string("Jane Doe <jane@example.org>"))
  assert_eq(map["conffiles"], Json::array([Json::string("/etc/hello.conf")]))
  assert_eq(map["conflicts"], Json::array([Json::string("hello-old<1.0")]))
  assert_eq(
    map["suggests"],
    Json::array([Json::string("less"), Json::string("man-db>2")]),
  )
  assert_eq(
    map["compression"],
    Json::object({ "payload": Json::string("zstd") }),
  )
}

///|
test "input that cannot be an Arch Linux package is refused" {
  let spec = sample_spec()
  let cases : Array[(@spec.PackageSpec, String)] = [
    ({ ..spec, arch: S390x, }, "arch: Arch Linux has no port for s390x"),
    (
      { ..spec, release: "1a", },
      "release: must be a number such as 1 or 1.1 for an Arch Linux package",
    ),
    (
      { ..spec, release: "1.2.3", },
      "release: must be a number such as 1 or 1.1 for an Arch Linux package",
    ),
    (
      { ..spec, provides: [@spec.Dependency::parse("x >= 1")], },
      "provides: \"x\": pacman only accepts = in a provide",
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
    try @arch.build(item.0) catch {
      err => assert_eq("\{err}", item.1)
    } noraise {
      _ => fail("expected an error: \{item.1}")
    }
  }
  try @arch.build(spec, compression=Lzma) catch {
    @arch.ArchError::Invalid(field~, ..) => assert_eq(field, "compression")
    err => fail("unexpected \{err}")
  } noraise {
    _ => fail("expected an error")
  }
  // An invalid spec is reported with its field.
  try @arch.build({ ..spec, name: "X", }) catch {
    @arch.ArchError::Invalid(field~, ..) => assert_eq(field, "name")
    err => fail("unexpected \{err}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "arch independent and other architectures" {
  let spec = { ..sample_spec(), arch: All, epoch: 0, }
  let pkg = @arch.read(@arch.build(spec))
  assert_eq(pkg.field("arch"), Some("any"))
  assert_eq(pkg.field("pkgver"), Some("1.2.3-4"))
  assert_eq(@arch.file_name(spec), "hello-1.2.3-4-any.pkg.tar.zst")
  assert_eq(
    @arch.file_name({ ..spec, arch: Arm64, }),
    "hello-1.2.3-4-aarch64.pkg.tar.zst",
  )
}

///|
fn change_entries(
  data : Bytes,
  change : (Array[@tar.Entry]) -> Array[@tar.Entry],
) -> Bytes raise {
  let tar = @compress.decompress(data, Zstd)
  @compress.compress(@tar.build(change(@tar.parse(tar))), Zstd)
}

///|
test "verify finds tampering" {
  let data = @arch.build(sample_spec())
  let check = (change : (Array[@tar.Entry]) -> Array[@tar.Entry]) => {
    @arch.read(change_entries(data, change)).verify()
  }
  // A different mode.
  let modes = check(entries => {
    entries.map(e => {
      if e.path == "usr/bin/hello" {
        { ..e, mode: 0o4755, }
      } else {
        e
      }
    })
  })
  assert_eq(modes, ["usr/bin/hello: mode 4755 in the package, 755 in .MTREE"])
  // A different link target.
  let links = check(entries => {
    entries.map(e => {
      if e.path == "usr/bin/hi" {
        { ..e, kind: Symlink("elsewhere"), }
      } else {
        e
      }
    })
  })
  assert_eq(links, [
    "usr/bin/hi: link target elsewhere in the package, hello in .MTREE",
  ])
  // A missing file.
  let missing = check(entries => entries.filter(e => e.path != "etc/hello.conf"))
  assert_eq(missing, ["etc/hello.conf: listed in .MTREE but not in the package"])
  // A file that is not listed.
  let extra = check(entries => {
    [..entries, @tar.Entry::file("usr/bin/evil", b"x")]
  })
  assert_eq(extra, ["usr/bin/evil: in the package but not listed in .MTREE"])
  // A file replaced by a directory.
  let kinds = check(entries => {
    entries.map(e => {
      if e.path == "usr/bin/hello" {
        { ..e, kind: Dir, }
      } else {
        e
      }
    })
  })
  assert_eq(kinds, ["usr/bin/hello: .MTREE says file, the package has a dir"])
  // Unsafe paths.
  let unsafe_ = check(entries => [..entries, @tar.Entry::file("../x", b"x")])
  assert_true(unsafe_.any(p => p == "../x: unsafe path"))
  let twice = check(entries => [..entries, entries[entries.length() - 1]])
  assert_true(twice.any(p => p.contains("appears twice")))
  // No .PKGINFO fields.
  let no_name = check(entries => {
    entries.map(e => {
      if e.path == ".PKGINFO" {
        @tar.Entry::file(".PKGINFO", b"pkgver = 1-1\narch = any\n")
      } else {
        e
      }
    })
  })
  assert_true(no_name.any(p => p == ".PKGINFO: missing pkgname"))
}

///|
test "reading refuses what is not an Arch Linux package" {
  let error_of = (data : Bytes) => {
    try @arch.read(data) catch {
      err => "\{err}"
    } noraise {
      _ => "ok"
    }
  }
  inspect(
    error_of(b""),
    content="corrupt package: there is no .PKGINFO, this is not an Arch Linux package",
  )
  inspect(
    error_of(b"hello world"),
    content="corrupt package: corrupt tar at offset 0: truncated header (11 bytes left)",
  )
  let no_info = @compress.compress(
    @tar.build([@tar.Entry::file("a", b"x")]),
    Zstd,
  )
  inspect(
    error_of(no_info),
    content="corrupt package: there is no .PKGINFO, this is not an Arch Linux package",
  )
  let bad_mtree = @compress.compress(
    @tar.build([
      @tar.Entry::file(".PKGINFO", b"pkgname = a\n"),
      @tar.Entry::file(".MTREE", b"not gzip"),
    ]),
    Zstd,
  )
  assert_true(error_of(bad_mtree).has_prefix("corrupt package: .MTREE: "))
  // A deb is not an Arch Linux package either.
  assert_true(
    error_of(@compress.compress(b"!<arch>\n", Xz)).has_prefix("corrupt package"),
  )
}

///|
test "a bomb is stopped" {
  let bomb = @compress.compress(Bytes::make(4 * 1024 * 1024, b'\x00'), Zstd)
  try @arch.read(bomb, max_unpacked=1024 * 1024) catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt package: the package unpacks to more than 1048576 bytes",
      )
  } noraise {
    _ => fail("expected the limit to be hit")
  }
}

///|
test "every truncation and flipped byte is handled" {
  let survives = (data : BytesView) => {
    try {
      let pkg = @arch.read(data)
      ignore(pkg.verify())
      ignore(pkg.to_json().stringify())
    } catch {
      _ => ()
    }
  }
  let kinds : Array[@compress.Compression] = [Zstd, Xz, Gzip, None]
  for compression in kinds {
    let data = @arch.build(sample_spec(), compression~)
    // The stream is long: look at a spread of positions.
    let step = data.length() / 250 + 1
    let mut at = 0
    while at < data.length() {
      survives(data[0:at])
      let copy = data.to_fixedarray()
      copy[at] = (copy[at].to_int() ^ 0xff).to_byte()
      survives(Bytes::from_array(copy[:]))
      at += step
    }
  }
}
