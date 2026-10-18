///|
fn root_file(
  path : String,
  content : Bytes,
  mode~ : Int32 = 0o644,
) -> @tar.Entry {
  @tar.Entry::file(path, content, mode~, mtime=1700000000L)
}

///|
test "archives written by GNU tar are read back" {
  let entries = @tar.parse(decode_fixture(ref_tree))
  assert_eq(entries, [
    @tar.Entry::dir("./usr/", mtime=1700000000L),
    root_file("./usr/hello", b"hi\n"),
    @tar.Entry::symlink("./usr/hi", "hello", mtime=1700000000L),
    root_file("./usr/run", b"#!/bin/sh\n", mode=0o755),
  ])
}

///|
test "ustar prefix names are joined" {
  let dir = "d".repeat(60) + "/" + "e".repeat(60)
  let entries = @tar.parse(decode_fixture(ref_long_prefix))
  assert_eq(entries, [root_file("./\{dir}/file.txt", b"x")])
}

///|
test "PAX extended headers from GNU tar" {
  let dir = "p".repeat(150) + "/" + "q".repeat(150)
  let entries = @tar.parse(decode_fixture(ref_pax))
  assert_eq(entries, [root_file("./\{dir}/file.txt", b"pax")])
}

///|
test "GNU long names and long links from GNU tar" {
  let dir = "g".repeat(150) + "/" + "h".repeat(150)
  let entries = @tar.parse(decode_fixture(ref_gnu))
  assert_eq(entries, [
    @tar.Entry::symlink(
      "./\{dir}/link",
      "../" + "t".repeat(200),
      mtime=1700000000L,
    ),
  ])
}

///|
fn sample_entries() -> Array[@tar.Entry] {
  [
    @tar.Entry::dir("./etc/", mtime=5L),
    @tar.Entry::file(
      "./etc/passwd-é",
      b"root:x:0:0\n",
      mode=0o600,
      uid=1000,
      gid=100,
      uname="alice",
      gname="staff",
      mtime=1700000000L,
    ),
    @tar.Entry::file("./empty", b""),
    @tar.Entry::file("./big", Bytes::make(1025, b'z')),
    @tar.Entry::symlink("./etc/link", "passwd-é"),
    @tar.Entry::file(
      "./" + "a".repeat(120) + "/" + "b".repeat(120) + "/c",
      b"deep",
    ),
    @tar.Entry::symlink("./long-link", "../" + "t".repeat(130)),
  ]
}

///|
test "build then parse is the identity in both long name modes" {
  for mode in [@tar.LongNames::Pax, @tar.LongNames::Gnu] {
    let entries = sample_entries()
    let archive = @tar.build(entries, long_names=mode)
    assert_eq(@tar.parse(archive), entries)
  }
}

///|
test "directories keep their trailing slash" {
  let parsed = @tar.parse(@tar.build([@tar.Entry::dir("./usr/bin")]))
  assert_eq(parsed[0].path, "./usr/bin/")
  assert_eq(parsed[0].kind, @tar.EntryKind::Dir)
}

///|
test "empty and unterminated archives" {
  assert_eq(@tar.parse(b"").length(), 0)
  assert_eq(@tar.parse(Bytes::make(1024, b'\x00')).length(), 0)
  // No end-of-archive blocks at all: the entries are still read.
  let archive = @tar.build([root_file("./f", b"x")])
  let without_end = archive[0:archive.length() - 1024]
  assert_eq(@tar.parse(without_end).length(), 1)
  // Trailing zero padding of any size is fine.
  let padded = Bytes::from_array([..archive, ..Bytes::make(9000, b'\x00')])
  assert_eq(@tar.parse(padded).length(), 1)
}

///|
test "parsing stops at the end marker" {
  let archive = @tar.build([root_file("./first", b"1")])
  let more = @tar.build([root_file("./second", b"2")])
  let both = Bytes::from_array([..archive, ..more])
  assert_eq(@tar.parse(both).map(e => e.path), ["./first"])
}

///|
fn mutate(archive : Bytes, change : (FixedArray[Byte]) -> Unit) -> Bytes {
  let copy : FixedArray[Byte] = FixedArray::makei(archive.length(), i => {
    archive[i]
  })
  change(copy)
  Bytes::from_array(copy[:])
}

///|
/// Recompute the checksum of the header block starting at `start`.
fn refresh_checksum(bytes : FixedArray[Byte], start : Int32) -> Unit {
  for i in 148..<156 {
    bytes[start + i] = b' '
  }
  let mut sum = 0
  for i in 0..<512 {
    sum += bytes[start + i].to_int()
  }
  let digits = @utf8.encode(sum.to_string(radix=8))
  for i in 0..<6 {
    let pad = 6 - digits.length()
    bytes[start + 148 + i] = if i < pad { b'0' } else { digits[i - pad] }
  }
  bytes[start + 154] = 0
  bytes[start + 155] = b' '
}

///|
fn parse_error(archive : BytesView) -> String {
  try @tar.parse(archive) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "corrupt headers are reported with their offset" {
  let good = @tar.build([root_file("./f", b"abc"), root_file("./g", b"def")])
  inspect(parse_error(good), content="ok")
  // A changed byte without a matching checksum.
  let flipped = mutate(good, b => b[3] = b'X')
  inspect(
    parse_error(flipped),
    content="corrupt tar at offset 0: header checksum is 4845, expected 4933",
  )
  // The same damage in the second header.
  let flipped2 = mutate(good, b => b[1024 + 3] = b'X')
  assert_true(
    parse_error(flipped2).has_prefix(
      "corrupt tar at offset 1024: header checksum is",
    ),
  )
  // A size that is not octal.
  let bad_size = mutate(good, b => {
    b[124] = b'8'
    refresh_checksum(b, 0)
  })
  inspect(
    parse_error(bad_size),
    content="corrupt tar at offset 0: size contains a byte that is not an octal digit",
  )
}

///|
test "truncated archives" {
  let archive = @tar.build([root_file("./f", Bytes::make(1000, b'k'))])
  inspect(
    parse_error(archive[0:600]),
    content="corrupt tar at offset 0: entry declares 1000 bytes but only 88 remain",
  )
  // A partial header that is not just zero padding.
  let garbage = Bytes::from_array([..@tar.build([]), ..Bytes::make(100, b'g')])
  let first = @tar.build([root_file("./f", b"x")])
  let cut = Bytes::from_array(
    [..first[0:first.length() - 1024], ..Bytes::make(100, b'g')],
  )
  inspect(
    parse_error(cut),
    content="corrupt tar at offset 1024: truncated header (100 bytes left)",
  )
  ignore(garbage)
}

///|
test "a long name header must be followed by an entry" {
  let archive = @tar.build(
    [root_file("./" + "n".repeat(300), b"x")],
    long_names=Gnu,
  )
  // Keep only the L header and its data block.
  inspect(
    parse_error(archive[0:1024]),
    content="corrupt tar at offset 1024: a long name header is not followed by an entry",
  )
}

///|
test "the number of entries is bounded" {
  let archive = @tar.build([root_file("./a", b""), root_file("./b", b"")])
  assert_eq(@tar.parse(archive, max_entries=2).length(), 2)
  inspect(
    parse_error_with_limit(archive, 1),
    content="corrupt tar at offset 512: more than 1 entries",
  )
}

///|
fn parse_error_with_limit(archive : Bytes, limit : Int32) -> String {
  try @tar.parse(archive, max_entries=limit) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "base-256 numbers and other entry types" {
  let archive = @tar.build([root_file("./f", b"abc")])
  // size = 3 written in GNU base-256 form
  let big = mutate(archive, b => {
    b[124] = 0x80
    for i in 125..<135 {
      b[i] = 0
    }
    b[135] = 3
    refresh_checksum(b, 0)
  })
  let parsed = @tar.parse(big)
  assert_eq(parsed[0].kind, @tar.EntryKind::File(b"abc"))
  // A hard link and a FIFO.
  let link = mutate(@tar.build([@tar.Entry::symlink("./l", "target")]), b => {
    b[156] = b'1'
    refresh_checksum(b, 0)
  })
  assert_eq(@tar.parse(link)[0].kind, @tar.EntryKind::Hardlink("target"))
  let fifo = mutate(@tar.build([@tar.Entry::dir("./p")]), b => {
    b[156] = b'6'
    refresh_checksum(b, 0)
  })
  assert_eq(@tar.parse(fifo)[0].kind, @tar.EntryKind::Special(54))
}

///|
test "hard links can be written and read" {
  let entries = [
    root_file("./a", b"data"),
    {
      ..@tar.Entry::symlink("./b", "./a"),
      kind: @tar.EntryKind::Hardlink("./a"),
    },
  ]
  let parsed = @tar.parse(@tar.build(entries))
  assert_eq(parsed[1].kind, @tar.EntryKind::Hardlink("./a"))
}

///|
test "special files cannot be written" {
  try
    @tar.build([
      { ..@tar.Entry::dir("./dev"), kind: @tar.EntryKind::Special(51), },
    ])
  catch {
    err => inspect("\{err}", content="kind: special files cannot be written")
  } noraise {
    _ => fail("expected an error")
  }
}
