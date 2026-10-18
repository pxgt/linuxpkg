///|
fn sample_rpm() -> Bytes raise {
  @rpm.build(
    @spec.PackageSpec::new(
      name="fuzz",
      version="1.0",
      arch=@spec.Arch::All,
      maintainer="Jane <jane@example.org>",
      description="Fuzz\nBody",
      depends=[@spec.Dependency::parse("bash >= 4")],
      entries=[
        @spec.Entry::file("/usr/bin/f", b"#!/bin/sh\n", mode=0o755),
        @spec.Entry::file("/etc/f.conf", b"x", config=true),
        @spec.Entry::symlink("/usr/bin/g", "f"),
      ],
    ),
  )
}

///|
fn survives(rpm : BytesView) -> Unit {
  try {
    let pkg = @rpm.read(rpm)
    ignore(pkg.files())
    ignore(pkg.verify())
    ignore(pkg.to_json().stringify())
  } catch {
    _ => ()
  }
}

///|
test "every truncation of an rpm is handled" {
  let rpm = sample_rpm()
  for cut in 0..<rpm.length() {
    survives(rpm[0:cut])
  }
}

///|
test "every flipped byte of an rpm is handled" {
  let rpm = sample_rpm()
  let copy : FixedArray[Byte] = FixedArray::makei(rpm.length(), i => rpm[i])
  for i in 0..<rpm.length() {
    let saved = copy[i]
    copy[i] = (saved.to_int() ^ 0xff).to_byte()
    survives(Bytes::from_array(copy[:]))
    copy[i] = 0
    survives(Bytes::from_array(copy[:]))
    copy[i] = saved
  }
}

///|
test "a payload that unpacks to a huge size is stopped" {
  let pkg = @rpm.read(sample_rpm())
  let bomb = @gzip.compress(Bytes::make(4 * 1024 * 1024, b'\x00'))
  let bombed = { ..pkg, payload: bomb, }
  try bombed.payload_entries(max_unpacked=1024 * 1024) catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt rpm: payload unpacks to more than 1048576 bytes",
      )
  } noraise {
    _ => fail("expected the limit to be hit")
  }
}

///|
/// The package with one tag of the main header replaced.
fn with_tag(rpm : Bytes, tag : @rpm.Tag) -> @rpm.RpmPackage raise {
  let pkg = @rpm.read(rpm)
  let tags = pkg.header.tags.map(t => if t.id == tag.id { tag } else { t })
  { ..pkg, header: { ..pkg.header, tags, }, }
}

///|
test "paths that escape the root and duplicate paths are reported" {
  let rpm = sample_rpm()
  let escaping = with_tag(rpm, {
    id: 1117,
    value: StrArray(["..", "f.conf", "g"]),
  })
  assert_true(escaping.verify().any(p => p.contains("/etc/..: path escapes")))
  let duplicated = with_tag(rpm, {
    id: 1117,
    value: StrArray(["f.conf", "f", "f"]),
  })
  assert_true(duplicated.verify().any(p => p.contains("listed more than once")))
}
