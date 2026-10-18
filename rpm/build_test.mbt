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
    vendor="Example Inc.",
    section="utils",
    depends=[
      @spec.Dependency::parse("libc6 >= 2.31"),
      @spec.Dependency::parse("bash"),
    ],
    conflicts=[@spec.Dependency::parse("hello-old (<< 1.0)")],
    replaces=[@spec.Dependency::parse("hello-old")],
    provides=[@spec.Dependency::parse("greeter (= 1)")],
    recommends=[@spec.Dependency::parse("less")],
    suggests=[@spec.Dependency::parse("man-db > 2")],
    entries=[
      @spec.Entry::file("/usr/bin/hello", b"abc", mode=0o755),
      @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
      @spec.Entry::symlink("/usr/bin/hi", "hello"),
      @spec.Entry::dir(
        "/var/lib/hello",
        mode=0o750,
        owner="hello",
        group="hello",
      ),
      @spec.Entry::file("/usr/bin/empty", b"", mtime=42L),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\nexit 0\n"),
      pre_remove: Some("#!/bin/sh\nexit 1\n"),
      post_remove: None,
    },
    mtime=1700000000L,
  )
}

///|
/// The parts of an rpm file.
priv struct Parts {
  lead : Bytes
  signature : @rpm.Header
  header_bytes : Bytes
  header : @rpm.Header
  payload : Bytes
  signature_end : Int32
}

///|
fn open_rpm(rpm : Bytes) -> Parts raise {
  let (signature, signature_end) = @rpm.Header::decode(rpm, 96)
  let main_start = (signature_end + 7) / 8 * 8
  let (header, main_end) = @rpm.Header::decode(rpm, main_start)
  {
    lead: rpm[0:96].to_owned(),
    signature,
    header_bytes: rpm[main_start:main_end].to_owned(),
    header,
    payload: rpm[main_end:].to_owned(),
    signature_end,
  }
}

///|
test "lead" {
  let parts = open_rpm(@rpm.build(sample_spec()))
  let expected = Bytes::from_array(
    [
      ..b"\xed\xab\xee\xdb\x03\x00\x00\x00\x00\x01",
      ..@utf8.encode("hello-1.2.3-4"),
      ..Bytes::make(66 - 13, b'\x00'),
      ..b"\x00\x01\x00\x05",
      ..Bytes::make(16, b'\x00'),
    ],
  )
  assert_eq(parts.lead, expected)
  assert_eq(parts.lead.length(), 96)
}

///|
test "file name" {
  assert_eq(@rpm.file_name(sample_spec()), "hello-1.2.3-4.x86_64.rpm")
  let all = { ..sample_spec(), arch: @spec.Arch::All, }
  assert_eq(@rpm.file_name(all), "hello-1.2.3-4.noarch.rpm")
}

///|
test "signature header carries size and digests" {
  let rpm = @rpm.build(sample_spec())
  let parts = open_rpm(rpm)
  assert_eq(parts.signature.region, Some(62))
  assert_eq(parts.signature.tags.map(t => t.id), [273, 1000, 1007])
  assert_eq(parts.signature.ints(1000), [
    parts.header_bytes.length() + parts.payload.length(),
  ])
  assert_eq(
    parts.signature.string(273),
    Some(@crypto.bytes_to_hex_string(@crypto.sha256(parts.header_bytes))),
  )
  let cpio = @gzip.decompress(parts.payload)
  assert_eq(parts.signature.ints(1007), [cpio.length()])
  // The main header starts at an 8 byte boundary after the signature.
  assert_eq(
    (rpm.length() - parts.payload.length() - parts.header_bytes.length()) % 8,
    0,
  )
  assert_true(parts.signature_end <= 96 + 8 * 100)
}

///|
test "package identity tags" {
  let parts = open_rpm(@rpm.build(sample_spec()))
  let h = parts.header
  assert_eq(h.region, Some(63))
  assert_eq(h.string(1000), Some("hello"))
  assert_eq(h.string(1001), Some("1.2.3"))
  assert_eq(h.string(1002), Some("4"))
  assert_eq(h.ints(1003), [2])
  assert_eq(h.get(1004), Some(@rpm.Value::I18n(["Says hello"])))
  assert_eq(h.get(1005), Some(@rpm.Value::I18n(["Says hello\nA longer text."])))
  assert_eq(h.ints(1006), [1700000000])
  assert_eq(h.string(1014), Some("Apache-2.0"))
  assert_eq(h.string(1011), Some("Example Inc."))
  assert_eq(h.string(1015), Some("Jane Doe <jane@example.org>"))
  assert_eq(h.string(1020), Some("https://example.org/hello"))
  assert_eq(h.string(1021), Some("linux"))
  assert_eq(h.string(1022), Some("x86_64"))
  assert_eq(h.string(1124), Some("cpio"))
  assert_eq(h.string(1125), Some("gzip"))
  assert_eq(h.string(1126), Some("9"))
  assert_eq(h.ints(5011), [8])
  assert_eq(h.ints(5093), [8])
  assert_eq(h.ints(1009), [3 + 4])
}

///|
test "files are sorted and described by parallel arrays" {
  let h = open_rpm(@rpm.build(sample_spec())).header
  assert_eq(h.strings(1117), ["hello.conf", "empty", "hello", "hi", "hello"])
  assert_eq(h.strings(1118), ["/etc/", "/usr/bin/", "/var/lib/"])
  assert_eq(h.ints(1116), [0, 1, 1, 1, 2])
  assert_eq(h.ints(1028), [4, 0, 3, 5, 0])
  assert_eq(h.ints(1030), [0o100644, 0o100644, 0o100755, 0o120777, 0o040750])
  assert_eq(h.ints(1034), [1700000000, 42, 1700000000, 1700000000, 1700000000])
  assert_eq(h.strings(1035), [
    "98752ee28d5484bdc2814fb70adb6a0b2fb31f6a9b8ee7ae81fd2fc9cf300b3b", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "", "",
  ])
  assert_eq(h.strings(1036), ["", "", "", "hello", ""])
  assert_eq(h.ints(1037), [1, 0, 0, 0, 0])
  assert_eq(h.strings(1039), ["root", "root", "root", "root", "hello"])
  assert_eq(h.strings(1040), ["root", "root", "root", "root", "hello"])
  assert_eq(h.ints(1096), [1, 2, 3, 4, 5])
  assert_eq(h.strings(1097), ["", "", "", "", ""])
  assert_eq(h.ints(1045), [-1, -1, -1, -1, -1])
}

///|
test "dependencies are mapped to names, flags and versions" {
  let h = open_rpm(@rpm.build(sample_spec())).header
  // Requires: user entries and the rpmlib features, sorted by name.
  assert_eq(h.strings(1049), [
    "bash", "libc6", "rpmlib(CompressedFileNames)", "rpmlib(FileDigests)", "rpmlib(PayloadFilesHavePrefix)",
  ])
  assert_eq(h.ints(1048), [
    0,
    12,
    0x1000000 | 10,
    0x1000000 | 10,
    0x1000000 | 10,
  ])
  assert_eq(h.strings(1050), ["", "2.31", "3.0.4-1", "4.6.0-1", "4.0-1"])
  // Provides: the package itself (with its epoch) and the declared one.
  assert_eq(h.strings(1047), ["greeter", "hello"])
  assert_eq(h.ints(1112), [8, 8])
  assert_eq(h.strings(1113), ["1", "2:1.2.3-4"])
  assert_eq(h.strings(1054), ["hello-old"])
  assert_eq(h.ints(1053), [2])
  assert_eq(h.strings(1055), ["1.0"])
  assert_eq(h.strings(1090), ["hello-old"])
  assert_eq(h.ints(1114), [0])
  assert_eq(h.strings(5046), ["less"])
  assert_eq(h.strings(5049), ["man-db"])
  assert_eq(h.ints(5051), [4])
  assert_eq(h.strings(5050), ["2"])
}

///|
test "maintainer scripts" {
  let h = open_rpm(@rpm.build(sample_spec())).header
  assert_eq(h.string(1024), Some("#!/bin/sh\nexit 0\n"))
  assert_eq(h.strings(1086), ["/bin/sh"])
  assert_eq(h.string(1025), Some("#!/bin/sh\nexit 1\n"))
  assert_eq(h.strings(1087), ["/bin/sh"])
  assert_eq(h.get(1023), None)
  assert_eq(h.get(1026), None)
}

///|
test "the payload is a gzip compressed cpio of the files in header order" {
  let parts = open_rpm(@rpm.build(sample_spec()))
  assert_eq(parts.header.strings(5092), [
    @crypto.bytes_to_hex_string(@crypto.sha256(parts.payload)),
  ])
  let entries = @cpio.parse(@gzip.decompress(parts.payload))
  assert_eq(entries.map(e => e.path), [
    "./etc/hello.conf", "./usr/bin/empty", "./usr/bin/hello", "./usr/bin/hi", "./var/lib/hello",
  ])
  assert_eq(entries.map(e => e.data), [b"x=1\n", b"", b"abc", b"hello", b""])
  assert_eq(entries.map(e => e.mode), [
    0o100644, 0o100644, 0o100755, 0o120777, 0o040750,
  ])
  assert_eq(entries.map(e => e.ino), [1, 2, 3, 4, 5])
  assert_eq(entries.map(e => e.mtime), [
    1700000000L, 42L, 1700000000L, 1700000000L, 1700000000L,
  ])
}

///|
test "a package without files has no file tags and an empty payload" {
  let spec = @spec.PackageSpec::new(
    name="meta",
    version="1",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Meta",
  )
  let parts = open_rpm(@rpm.build(spec))
  assert_eq(parts.header.get(1117), None)
  assert_eq(parts.header.get(1118), None)
  assert_eq(parts.header.ints(1009), [0])
  assert_eq(parts.header.string(1014), Some("Unspecified"))
  assert_eq(parts.header.get(1003), None)
  assert_eq(@cpio.parse(@gzip.decompress(parts.payload)).length(), 0)
}

///|
test "building twice gives identical bytes" {
  assert_eq(@rpm.build(sample_spec()), @rpm.build(sample_spec()))
}

///|
fn build_error(spec : @spec.PackageSpec) -> String {
  try @rpm.build(spec) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "invalid specs are rejected" {
  inspect(
    build_error({ ..sample_spec(), name: "Hello", }),
    content="name: must be lowercase",
  )
  inspect(
    build_error({ ..sample_spec(), mtime: 4294967296L, }),
    content="mtime: 4294967296 does not fit in 32 bits",
  )
  inspect(
    build_error({
      ..sample_spec(),
      entries: [@spec.Entry::file("/a", b"", mtime=4294967296L)],
    }),
    content="/a: modification time 4294967296 does not fit in 32 bits",
  )
}
