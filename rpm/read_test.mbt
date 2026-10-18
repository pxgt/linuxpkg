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
fn read_error(bytes : BytesView) -> String {
  try {
    ignore(@rpm.read(bytes))
    "ok"
  } catch {
    err => "\{err}"
  }
}

///|
fn verify_outcome(bytes : BytesView) -> String {
  try {
    let pkg = @rpm.read(bytes)
    let problems = pkg.verify()
    if problems.length() == 0 {
      "ok"
    } else {
      problems.join(" | ")
    }
  } catch {
    err => "error: \{err}"
  }
}

///|
test "an rpm written by the real rpmbuild is understood" {
  let pkg = @rpm.read(decode_hex(real_gzip_rpm))
  let h = pkg.header
  assert_eq(pkg.lead_name, "realrpm-2.5-3")
  assert_eq(h.string(1000), Some("realrpm"))
  assert_eq(h.string(1001), Some("2.5"))
  assert_eq(h.string(1002), Some("3"))
  assert_eq(h.string(1022), Some("noarch"))
  assert_eq(h.string(1014), Some("MIT"))
  assert_eq(h.string(1020), Some("https://example.org/realrpm"))
  assert_eq(h.strings(1004), ["A package built by rpmbuild"])
  assert_eq(pkg.compressor(), "gzip")
  assert_eq(pkg.signature.region, Some(62))
  assert_eq(h.region, Some(63))
  let files = pkg.files()
  assert_eq(files.map(f => f.path), [
    "/etc/realrpm.conf", "/usr/share/realrpm", "/usr/share/realrpm/data.txt", "/usr/share/realrpm/link",
  ])
  assert_eq(files.map(f => f.size), [10L, 0L, 20L, 8L])
  assert_eq(files.map(f => f.mode), [0o100644, 0o040755, 0o100644, 0o120777])
  assert_eq(files.map(f => f.flags), [17, 0, 0, 0])
  assert_eq(files[3].link, "data.txt")
  assert_eq(files[0].owner, "root")
  assert_eq(files[0].mtime, 1700000000L)
  assert_eq(
    files[0].digest,
    "2bb264bf86e6547af86ce050ef56c3c569dea500d3f3512f528584aabc7f62d1",
  )
}

///|
test "dependencies and the JSON report of a real rpm" {
  let pkg = @rpm.read(decode_hex(real_gzip_rpm))
  let report = pkg.to_json()
  guard report is Object(map) else { fail("report must be an object") }
  assert_eq(map["format"], Json::string("rpm"))
  assert_eq(map["name"], Json::string("realrpm"))
  assert_eq(map["version"], Json::string("2.5"))
  assert_eq(map["release"], Json::string("3"))
  assert_eq(map["architecture"], Json::string("noarch"))
  assert_eq(map["epoch"], Json::null())
  assert_eq(map["summary"], Json::string("A package built by rpmbuild"))
  assert_eq(
    map["depends"],
    Json::array([Json::string("/bin/sh"), Json::string("bash >= 4.0")]),
  )
  assert_eq(
    map["provides"],
    Json::array([Json::string("realrpm = 2.5-3"), Json::string("realthing = 1")]),
  )
  assert_eq(map["conflicts"], Json::array([Json::string("oldthing < 2")]))
  assert_eq(map["conffiles"], Json::array([Json::string("/etc/realrpm.conf")]))
  assert_eq(map["scripts"], Json::array([Json::string("post")]))
  assert_eq(
    map["compression"],
    Json::object({ "payload": Json::string("gzip") }),
  )
  assert_eq(
    map["signature"],
    Json::array([
      Json::string("sha1"),
      Json::string("sha256"),
      Json::string("size"),
      Json::string("md5"),
      Json::string("payloadsize"),
      Json::string("reserved"),
    ]),
  )
}

///|
test "verify accepts a real rpm with all its digests" {
  inspect(verify_outcome(decode_hex(real_gzip_rpm)), content="ok")
}

///|
test "xz and zstd payloads can be inspected but not verified" {
  for pair in [(real_xz_rpm, "xz"), (real_zstd_rpm, "zstd")] {
    let bytes = decode_hex(pair.0)
    let pkg = @rpm.read(bytes)
    assert_eq(pkg.header.string(1000), Some("realrpm"))
    assert_eq(pkg.files().length(), 4)
    assert_eq(pkg.compressor(), pair.1)
    inspect(
      verify_outcome(bytes),
      content="error: unsupported rpm: \{pair.1} compression of the payload is not supported (only gzip and uncompressed payloads)",
    )
    try pkg.payload_entries() catch {
      Unsupported(..) => ()
      err => fail("unexpected error \{err}")
    } noraise {
      _ => fail("expected an error")
    }
  }
}

///|
fn tamper(bytes : Bytes, at : Int32) -> Bytes {
  let copy : FixedArray[Byte] = FixedArray::makei(bytes.length(), i => bytes[i])
  copy[at] = (copy[at].to_int() ^ 0xff).to_byte()
  Bytes::from_array(copy[:])
}

///|
test "verify finds damage in each part of an rpm" {
  let good = decode_hex(real_gzip_rpm)
  let pkg = @rpm.read(good)
  let payload_start = good.length() - pkg.payload.length()
  // A changed byte in the compressed payload.
  let damaged_payload = tamper(good, payload_start + 30)
  let outcome = verify_outcome(damaged_payload)
  assert_true(outcome.contains("payload digest mismatch"))
  // A changed byte inside the main header (the package name).
  let header_start = payload_start - pkg.header_bytes.length()
  // Flip a letter inside the summary text, which keeps the header parseable.
  let needle = @utf8.encode("A package built")
  let mut at = 0
  for i in 0..<(pkg.header_bytes.length() - needle.length()) {
    if pkg.header_bytes[i:i + needle.length()].to_owned() == needle {
      at = i
      break
    }
  }
  let damaged_header = tamper(good, header_start + at + 2)
  assert_true(
    verify_outcome(damaged_header).contains("header SHA-256 mismatch"),
  )
  // Truncated files.
  assert_true(read_error(good[0:payload_start - 10]).has_prefix("corrupt rpm"))
  inspect(
    read_error(good[0:50]),
    content="corrupt rpm at offset 0: file is 50 bytes long, shorter than the 96 byte lead",
  )
  inspect(
    read_error(good[0:100]),
    content="corrupt rpm at offset 96: truncated header (4 bytes left)",
  )
}

///|
test "a file changed behind the digests' back is caught by file digests" {
  // Rebuild the package with a modified payload but copy the digests: build
  // our own rpm, then swap the content in a payload that keeps the header.
  let spec = @spec.PackageSpec::new(
    name="forge",
    version="1",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Forge",
    entries=[@spec.Entry::file("/opt/f", b"genuine")],
  )
  let built = @rpm.build(spec)
  let pkg = @rpm.read(built)
  assert_eq(pkg.verify(), [])
  let forged_cpio = @cpio.build([
    @cpio.Entry::file("./opt/f", b"forgery", ino=1),
  ])
  let forged = { ..pkg, payload: @gzip.compress(forged_cpio), }
  let problems = forged.verify()
  assert_true(problems.length() > 0)
  assert_true(problems[0].contains("payload digest mismatch"))
  // Fix up the payload digest so only the file digest can notice.
  let forged_digest = @crypto.bytes_to_hex_string(
    @crypto.sha256(forged.payload),
  )
  let tags = pkg.header.tags.map(t => {
    if t.id == 5092 {
      @rpm.Tag::{ id: 5092, value: @rpm.Value::StrArray([forged_digest]), }
    } else {
      t
    }
  })
  let rehosted = { ..forged, header: { ..pkg.header, tags, }, }
  let found = rehosted.verify()
  assert_true(found.any(p => p.contains("/opt/f: digest mismatch")))
}

///|
test "not an rpm" {
  inspect(
    read_error(Bytes::make(200, b'x')),
    content="corrupt rpm at offset 0: missing rpm magic, this is not an rpm",
  )
  let wrong_version = decode_hex(real_gzip_rpm)
  inspect(
    read_error(tamper(wrong_version, 4)),
    content="unsupported rpm: rpm lead version 252.0 (only 3.x is supported)",
  )
}

///|
test "our own rpm round trips through the reader" {
  let spec = @spec.PackageSpec::new(
    name="own",
    version="1.0",
    epoch=3,
    arch=@spec.Arch::Amd64,
    maintainer="Jane <jane@example.org>",
    description="Own\nBody",
    depends=[@spec.Dependency::parse("libc6 >= 2.31")],
    entries=[
      @spec.Entry::file("/usr/bin/own", b"#!/bin/sh\n", mode=0o755),
      @spec.Entry::symlink("/usr/bin/o", "own"),
    ],
  )
  let pkg = @rpm.read(@rpm.build(spec))
  assert_eq(pkg.verify(), [])
  assert_eq(pkg.files().map(f => f.path), ["/usr/bin/o", "/usr/bin/own"])
  guard pkg.to_json() is Object(map) else { fail("object expected") }
  assert_eq(map["epoch"], Json::number(3.0))
  assert_eq(map["depends"], Json::array([Json::string("libc6 >= 2.31")]))
  assert_eq(map["architecture"], Json::string("x86_64"))
  assert_eq(map["description"], Json::string("Own\nBody"))
  assert_eq(pkg.payload_entries().length(), 2)
}
