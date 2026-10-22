///|
priv struct Rng {
  mut state : Int64
}

///|
fn Rng::next(self : Rng) -> Int32 {
  self.state = self.state * 6364136223846793005L + 1442695040888963407L
  ((self.state >> 33) & 0x7fffffffL).to_int()
}

///|
fn Rng::below(self : Rng, n : Int32) -> Int32 {
  self.next() % n
}

///|
fn Rng::bytes(self : Rng, n : Int32) -> Bytes {
  Bytes::makei(n, _ => self.below(256).to_byte())
}

///|
fn Rng::word(self : Rng, max : Int32) -> String {
  let n = 1 + self.below(max)
  let out = StringBuilder()
  for _ in 0..<n {
    out.write_char(
      "abcdefghijklmnopqrstuvwxyz0123456789-_."
      .unsafe_get(self.below(39))
      .unsafe_to_char(),
    )
  }
  out.to_string()
}

///|
fn trim_slash(path : String) -> String {
  if path.has_suffix("/") {
    path[0:path.length() - 1].to_owned()
  } else {
    path
  }
}

///|
/// Random entries with distinct names: files of any size up to a few blocks,
/// directories and symbolic links.
fn random_entries(
  rng : Rng,
  count : Int32,
  name_max : Int32,
) -> Array[@tar.Entry] {
  let entries : Array[@tar.Entry] = []
  for i in 0..<count {
    let path = "d\{i}/" + rng.word(name_max)
    let mode = rng.below(0o7777 + 1)
    let mtime = rng.next().to_int64()
    match rng.below(3) {
      0 => entries.push(@tar.Entry::dir(path + "/", mode~, mtime~))
      1 => entries.push(@tar.Entry::symlink(path, rng.word(40), mtime~))
      _ =>
        entries.push(
          @tar.Entry::file(path, rng.bytes(rng.below(1600)), mode~, mtime~),
        )
    }
  }
  entries
}

///|
fn same_entry(a : @tar.Entry, b : @tar.Entry) -> Bool {
  trim_slash(a.path) == trim_slash(b.path) &&
  a.kind == b.kind &&
  a.mode == b.mode &&
  a.mtime == b.mtime &&
  a.uid == b.uid &&
  a.gid == b.gid &&
  a.uname == b.uname &&
  a.gname == b.gname
}

///|
fn round_trips(
  entries : Array[@tar.Entry],
  names : @tar.LongNames,
) -> Bool raise {
  let parsed = @tar.parse(@tar.build(entries, long_names=names)[:])
  if parsed.length() != entries.length() {
    return false
  }
  for i, e in entries {
    if !same_entry(e, parsed[i]) {
      return false
    }
  }
  true
}

///|
test "property: random archives read back as written (PAX long names)" {
  let rng = { state: 7L, }
  for round in 0..<25 {
    ignore(round)
    assert_true(round_trips(random_entries(rng, 1 + rng.below(12), 30), Pax))
  }
}

///|
test "property: random archives read back as written (GNU long names)" {
  let rng = { state: 11L, }
  for round in 0..<25 {
    ignore(round)
    assert_true(round_trips(random_entries(rng, 1 + rng.below(12), 30), Gnu))
  }
}

///|
test "property: names from 60 to 700 bytes survive in both long name styles" {
  let rng = { state: 5L, }
  for len in [60, 99, 100, 101, 154, 155, 156, 255, 256, 300, 700] {
    let path = "a/" + "x".repeat(len) + rng.word(5)
    for names in [@tar.LongNames::Pax, @tar.LongNames::Gnu] {
      assert_true(round_trips([@tar.Entry::file(path, b"data")], names))
    }
  }
}

///|
test "property: file sizes around the block size are padded and read back" {
  let rng = { state: 3L, }
  for size in [0, 1, 255, 511, 512, 513, 1023, 1024, 1025, 4095, 4096, 5000] {
    let data = rng.bytes(size)
    let archive = @tar.build([@tar.Entry::file("f", data)])
    assert_eq(archive.length() % 512, 0)
    assert_eq(archive.length(), 512 + (size + 511) / 512 * 512 + 1024)
    match @tar.parse(archive[:])[0].kind {
      File(content) => assert_eq(content, data)
      _ => fail("not a file")
    }
  }
}

///|
test "property: an archive ends with two zero blocks and building is deterministic" {
  let rng = { state: 21L, }
  for _ in 0..<10 {
    let entries = random_entries(rng, 5, 20)
    let a = @tar.build(entries)
    assert_eq(a, @tar.build(entries))
    assert_eq(a[a.length() - 1024:].to_owned(), Bytes::make(1024, b'\x00'))
  }
}

///|
test "names with spaces and non-ASCII letters are kept" {
  for
    name in [
      "with space/file name.txt", "ünïcödé/fïle", "日本語/ファイル",
      "emoji-😀/x", "tab\there",
    ] {
    let e = @tar.Entry::file(name, b"x")
    for names in [@tar.LongNames::Pax, @tar.LongNames::Gnu] {
      let parsed = @tar.parse(@tar.build([e], long_names=names)[:])
      assert_eq(parsed[0].path, name)
    }
  }
}

///|
test "owner names and numeric ids are kept" {
  for
    case in [("root", 0), ("a", 1000), ("n".repeat(31), 65534), ("u", 2097151)] {
    let e = @tar.Entry::file(
      "f",
      b"x",
      uname=case.0,
      gname=case.0,
      uid=case.1,
      gid=case.1,
    )
    let parsed = @tar.parse(@tar.build([e])[:])[0]
    assert_eq(parsed.uname, case.0)
    assert_eq(parsed.uid, case.1)
  }
}

///|
test "modification times up to 2^33 survive" {
  for t in [0L, 1L, 1700000000L, 2147483647L, 2147483648L, 8589934591L] {
    let e = @tar.Entry::file("f", b"x", mtime=t)
    assert_eq(@tar.parse(@tar.build([e])[:])[0].mtime, t)
  }
}

///|
test "property: PAX records of any key and value read back with their entry" {
  let rng = { state: 99L, }
  for _ in 0..<15 {
    let items : Array[(@tar.Entry, Array[(String, String)])] = []
    for i in 0..<(1 + rng.below(4)) {
      let records : Array[(String, String)] = []
      for j in 0..<rng.below(4) {
        records.push(("K\{j}.\{rng.word(8)}", rng.word(120)))
      }
      items.push(
        (@tar.Entry::file("f\{i}", rng.bytes(rng.below(700))), records),
      )
    }
    let archive = @tar.build_with_records(items)
    let parsed = @tar.parse_with_records(archive[:])
    assert_eq(parsed.length(), items.length())
    for i, item in items {
      assert_eq(parsed[i].0.path, item.0.path)
      assert_eq(parsed[i].1, item.1)
    }
  }
}

///|
test "an archive without end marker still reads" {
  let rng = { state: 4L, }
  let entries = random_entries(rng, 4, 20)
  let items = entries.map(e => (e, []))
  let archive = @tar.build_with_records(items, end_marker=false)
  assert_eq(archive.length() % 512, 0)
  assert_eq(@tar.parse(archive[:]).length(), 4)
}

///|
test "property: cutting an archive anywhere gives an error or fewer entries, never a crash" {
  let rng = { state: 17L, }
  let archive = @tar.build(random_entries(rng, 6, 20))
  let mut cut = 0
  while cut < archive.length() {
    ignore(
      try @tar.parse(archive[0:cut]) catch {
        _ => []
      } noraise {
        parsed => parsed
      },
    )
    cut += 37
  }
}
