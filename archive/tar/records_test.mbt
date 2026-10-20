///|
test "extra PAX records survive a round trip" {
  let long = "./" + "d".repeat(120) + "/" + "f".repeat(110)
  let items : Array[(@tar.Entry, Array[(String, String)])] = [
    (
      @tar.Entry::file("a.txt", b"hello", mtime=7L),
      [("APK-TOOLS.checksum.SHA1", "aaaa"), ("ctime", "0")],
    ),
    (@tar.Entry::dir("dir"), []),
    (@tar.Entry::file(long, b"long"), [("X.key", "värde")]),
  ]
  for names in [@tar.LongNames::Pax, Gnu] {
    let archive = @tar.build_with_records(items, long_names=names)
    let parsed = @tar.parse_with_records(archive)
    assert_eq(parsed.length(), 3)
    assert_eq(parsed[0].0.path, "a.txt")
    assert_eq(parsed[0].0.kind, @tar.EntryKind::File(b"hello"))
    assert_eq(parsed[0].0.mtime, 7L)
    // `ctime` is not interpreted by the reader, so it is reported too.
    assert_eq(parsed[0].1, [("APK-TOOLS.checksum.SHA1", "aaaa"), ("ctime", "0")])
    assert_eq(parsed[1].1, [])
    assert_eq(parsed[2].0.path, long)
    assert_eq(parsed[2].1, [("X.key", "värde")])
    // Plain `parse` ignores the records and gives the same entries.
    assert_eq(@tar.parse(archive), parsed.map(p => p.0))
  }
}

///|
test "an archive can be written without its end marker" {
  let items : Array[(@tar.Entry, Array[(String, String)])] = [
    (@tar.Entry::file("a", b"x"), []),
  ]
  let with_marker = @tar.build_with_records(items)
  let without = @tar.build_with_records(items, end_marker=false)
  assert_eq(with_marker.length() - without.length(), 1024)
  assert_eq(@tar.parse(without).length(), 1)
  assert_eq(@tar.parse(with_marker), @tar.parse(without))
}

///|
test "records the reader interprets are not reported as extra" {
  let archive = @tar.build_with_records([
    (
      @tar.Entry::file("a", b"x"),
      [("mtime", "42"), ("uname", "bob"), ("k", "v")],
    ),
  ])
  let parsed = @tar.parse_with_records(archive)
  assert_eq(parsed[0].0.mtime, 42L)
  assert_eq(parsed[0].0.uname, "bob")
  assert_eq(parsed[0].1, [("k", "v")])
}

///|
test "bad record keys and values are refused" {
  for pair in [("", "x"), ("k\u{0}", "x"), ("k", "a\u{0}b")] {
    try @tar.build_with_records([(@tar.Entry::file("a", b"x"), [pair])]) catch {
      @tar.TarError::Invalid(..) => ()
      err => fail("unexpected \{err}")
    } noraise {
      _ => fail("expected an error for \{pair.0}/\{pair.1}")
    }
  }
}
