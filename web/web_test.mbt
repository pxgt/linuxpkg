///|
const CONFIG : String =
  #|{"name":"hello","version":"1.0.0","arch":"all","maintainer":"J <j@example.org>","description":"Demo\nLonger text","license":"MIT","mtime":1700000000,
  #| "contents":[{"src":"hello.sh","dst":"/usr/bin/hello","mode":"0755"},{"src":"hello.conf","dst":"/etc/hello.conf","type":"config"}]}

///|
fn files_json() -> String {
  let script = @base64.encode(b"#!/bin/sh\necho hi\n"[:])
  let conf = @base64.encode(b"x=1\n"[:])
  "{\"hello.sh\":\"\{script}\",\"hello.conf\":\"\{conf}\"}"
}

///|
fn parse(text : String) -> Json raise {
  @json.parse(text)
}

///|
fn built(formats : String) -> Array[Json] raise {
  match parse(@web.lp_build(CONFIG, files_json(), formats, "", 0.0)) {
    { "packages": Array(items), .. } => items
    _ => fail("no packages")
  }
}

///|
fn text_of(json : Json, key : String) -> String raise {
  match json {
    Object(map) =>
      match map.get(key) {
        Some(String(text)) => text
        _ => fail("no \{key}")
      }
    _ => fail("not an object")
  }
}

///|
test "build makes the four formats with their usual names" {
  let names = built("all").map(p => text_of(p, "name"))
  assert_eq(names, [
    "hello_1.0.0-1_all.deb", "hello-1.0.0-1.noarch.rpm", "hello-1.0.0-1-any.pkg.tar.zst",
    "hello-1.0.0-r1.apk",
  ])
}

///|
test "build gives the bytes of the library" {
  let spec = @spec.Config::parse(CONFIG).resolve(
    { "hello.sh": b"#!/bin/sh\necho hi\n", "hello.conf": b"x=1\n" },
    default_mtime=0L,
  )
  let deb = @base64.decode(text_of(built("deb")[0], "data"))
  assert_eq(deb, @deb.build(spec))
  let rpm = @base64.decode(text_of(built("rpm")[0], "data"))
  assert_eq(rpm, @rpm.build(spec))
}

///|
test "build: one format, compression and the default time" {
  assert_eq(built("apk").length(), 1)
  let items = match
    parse(@web.lp_build(CONFIG, files_json(), "deb", "zstd", 0.0)) {
    { "packages": Array(items), .. } => items
    _ => fail("no packages")
  }
  let zst = @base64.decode(text_of(items[0], "data"))
  assert_eq(@deb.read(zst).data_compression, "zstd")
  let no_mtime = CONFIG.replace(old="\"mtime\":1700000000,", new="")
  let a = @web.lp_build(no_mtime, files_json(), "deb", "", 5.0)
  let b = @web.lp_build(no_mtime, files_json(), "deb", "", 6.0)
  assert_true(a != b)
  assert_eq(a, @web.lp_build(no_mtime, files_json(), "deb", "", 5.0))
}

///|
test "build reports problems as JSON, never as a crash" {
  for
    case in [
      ("{", files_json(), "all", ""),
      ("{}", files_json(), "all", ""),
      (CONFIG, "{}", "all", ""),
      (CONFIG, "[]", "all", ""),
      (CONFIG, "{\"hello.sh\":5}", "all", ""),
      (CONFIG, "{\"hello.sh\":\"!!\",\"hello.conf\":\"\"}", "all", ""),
      (CONFIG, files_json(), "all", "bzip2"),
    ] {
    match parse(@web.lp_build(case.0, case.1, case.2, case.3, 0.0)) {
      { "error": String(message), .. } => assert_true(message != "")
      _ => fail("expected an error for \{case.0}")
    }
  }
}

///|
test "inspect reads every kind and reports the same fields" {
  for pkg in built("all") {
    let name = text_of(pkg, "name")
    let info = parse(@web.lp_inspect(name, text_of(pkg, "data")))
    assert_eq(text_of(info, "kind"), text_of(pkg, "format"))
    match info {
      { "report": Object(report), "problems": Array(problems), .. } => {
        assert_eq(problems.length(), 0)
        assert_true(report.get("files") is Some(Array(_)))
        match report.get("name") {
          Some(String(n)) => assert_eq(n, "hello")
          _ => fail("no name")
        }
      }
      _ => fail("unexpected shape for \{name}")
    }
  }
}

///|
test "verify counts checksums and finds damage" {
  for pkg in built("all") {
    let name = text_of(pkg, "name")
    let data = @base64.decode(text_of(pkg, "data"))
    match parse(@web.lp_verify(name, text_of(pkg, "data"), "")) {
      { "checked": Number(n, ..), "problems": Array([]), .. } =>
        assert_true(n > 0.0)
      _ => fail("not verified: \{name}")
    }
    let damaged = data.to_array()
    damaged[damaged.length() - 20] = damaged[damaged.length() - 20] ^ 0xff
    let report = parse(
      @web.lp_verify(name, @base64.encode(Bytes::from_array(damaged)[:]), ""),
    )
    let bad = match report {
      { "error": String(_), .. } => true
      { "problems": Array(p), .. } => p.length() > 0
      _ => false
    }
    assert_true(bad)
  }
}

///|
fn sig_state(data : Bytes, keyring : String) -> String raise {
  match parse(@web.lp_verify("x.rpm", @base64.encode(data[:]), keyring)) {
    { "signature": Object(sig), .. } => text_of(Json::object(sig), "state")
    _ => "?"
  }
}

///|
test "signature state: unsigned, signed, good and bad" {
  let plain = @rpm.build(
    @spec.Config::parse(CONFIG).resolve(
      { "hello.sh": b"x", "hello.conf": b"y" },
      default_mtime=0L,
    ),
  )
  let key = @sign.SigningKey::from_armored(fx_rsa_secret)
  let signed = @rpm.sign(plain, key, created=1800000000L)
  assert_eq(sig_state(plain, ""), "unsigned")
  assert_eq(sig_state(signed, ""), "signed")
  assert_eq(sig_state(signed, fx_rsa_public), "good")
  assert_eq(sig_state(signed, fx_ed_public), "bad")
  let ed_signed = @rpm.sign(
    plain,
    @sign.SigningKey::from_armored(fx_ed_secret),
    created=1800000000L,
  )
  assert_eq(sig_state(ed_signed, fx_ed_public), "good")
  assert_eq(sig_state(ed_signed, fx_rsa_public), "bad")
  assert_eq(sig_state(signed, "not a key"), "?")
}

///|
test "the file name tells an Alpine package from an Arch one" {
  let apk = @apk.build(
    @spec.Config::parse(CONFIG).resolve(
      { "hello.sh": b"x", "hello.conf": b"y" },
      default_mtime=0L,
    ),
  )
  let b64 = @base64.encode(apk[:])
  assert_eq(text_of(parse(@web.lp_inspect("hello.apk", b64)), "kind"), "apk")
  assert_eq(text_of(parse(@web.lp_inspect("something", b64)), "kind"), "apk")
}

///|
test "inspect of things that are not packages is an error object" {
  for
    case in [
      ("x.deb", ""),
      ("x.deb", "!!!"),
      ("x.rpm", "AAAA"),
      ("x.apk", "H4sI"),
    ] {
    match parse(@web.lp_inspect(case.0, case.1)) {
      { "error": String(_), .. } => ()
      _ => fail("expected an error")
    }
  }
}

///|
/// The 64-byte header of an arm64 ELF file: what `inspect` reads, not a program.
fn arm64_header() -> Bytes {
  let bytes : Array[Byte] = [
    0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0xb7, 0, 1,
  ]
  for _ in 0..<(64 - bytes.length()) {
    bytes.push(0)
  }
  Bytes::from_array(bytes)
}

///|
const ELF_CONFIG : String =
  #|{"name":"prog","version":"1","arch":"arm64","maintainer":"J <j@example.org>","description":"Demo","mtime":1700000000,
  #| "contents":[{"src":"prog","dst":"/usr/bin/prog","mode":"0755"},{"src":"note","dst":"/usr/share/doc/prog/note"}]}

///|
fn elf_files_json() -> String {
  let program = @base64.encode(arm64_header()[:])
  let note = @base64.encode(b"hello\n"[:])
  "{\"prog\":\"\{program}\",\"note\":\"\{note}\"}"
}

///|
test "inspect shows the ELF facts of a file in every package format" {
  let items = match
    parse(@web.lp_build(ELF_CONFIG, elf_files_json(), "all", "", 0.0)) {
    { "packages": Array(items), .. } => items
    _ => fail("no packages")
  }
  assert_eq(items.length(), 4)
  for pkg in items {
    let name = text_of(pkg, "name")
    guard parse(@web.lp_inspect(name, text_of(pkg, "data")))
      is { "report": Object(report), .. } else {
      fail("no report for \{name}")
    }
    guard report.get("files") is Some(Array(files)) else {
      fail("no files for \{name}")
    }
    let mut seen = 0
    for file in files {
      guard file is Object(entry) else { fail("not an object") }
      match entry.get("elf") {
        Some(Object(elf)) => {
          seen += 1
          assert_true(text_of(file, "path").has_suffix("/usr/bin/prog"))
          assert_eq(text_of(Json::object(elf), "arch"), "arm64")
          assert_eq(text_of(Json::object(elf), "linkage"), "static")
        }
        Some(Null) => ()
        _ => fail("missing elf key for \{name}")
      }
    }
    assert_eq(seen, 1)
  }
}

///|
test "build refuses an ELF file of another architecture and reports warnings" {
  let amd64 = ELF_CONFIG.replace(
    old="\"arch\":\"arm64\"",
    new="\"arch\":\"amd64\"",
  )
  match parse(@web.lp_build(amd64, elf_files_json(), "deb", "", 0.0)) {
    { "error": String(message), .. } => {
      assert_true(message.contains("arm64"))
      assert_true(message.contains("amd64"))
    }
    _ => fail("expected an error")
  }
  let independent = ELF_CONFIG.replace(
    old="\"arch\":\"arm64\"",
    new="\"arch\":\"all\"",
  )
  match parse(@web.lp_build(independent, elf_files_json(), "deb", "", 0.0)) {
    { "packages": Array(_), "warnings": Array([String(warning)]), .. } =>
      assert_true(warning.contains("arm64"))
    _ => fail("expected one warning")
  }
}
