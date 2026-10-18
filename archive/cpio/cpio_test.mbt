///|
fn hex_value(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    _ => abort("bad hex digit in fixture")
  }
}

///|
fn decode_fixture(text : String) -> Bytes {
  let out : Array[Byte] = []
  for token in text.replace_all(old="\n", new=" ").split(" ") {
    if token.length() == 0 {
      continue
    }
    if token[0] == 'Z' {
      let mut count = 0
      for c in token[1:] {
        count = count * 10 + (c.to_int() - '0'.to_int())
      }
      for _ in 0..<count {
        out.push(b'\x00')
      }
    } else {
      let chars = token.to_array()
      for i = 0; i < chars.length(); i = i + 2 {
        out.push((hex_value(chars[i]) * 16 + hex_value(chars[i + 1])).to_byte())
      }
    }
  }
  Bytes::from_array(out[:])
}

///|
fn reference_entries() -> Array[@cpio.Entry] {
  [
    { ..@cpio.Entry::dir("usr", mtime=1700000000L, ino=0), },
    @cpio.Entry::file("usr/hello", b"hi\n", mtime=1700000000L, ino=1),
    @cpio.Entry::symlink("usr/hi", "hello", mtime=1700000000L, ino=2),
    @cpio.Entry::file(
      "usr/run",
      b"#!/bin/sh\n",
      mode=0o100755,
      mtime=1700000000L,
      ino=3,
    ),
  ]
}

///|
test "GNU cpio's archive is read" {
  let entries = @cpio.parse(decode_fixture(ref_tree))
  assert_eq(entries.map(e => e.path), ["usr", "usr/hello", "usr/hi", "usr/run"])
  assert_eq(entries[1].data, b"hi\n")
  assert_eq(entries[2].data, b"hello")
  assert_eq(entries[2].mode, 0o120777)
  assert_eq(entries[3].mode, 0o100755)
  assert_eq(entries[0].mode, 0o040755)
  assert_eq(entries[0].mtime, 1700000000L)
  assert_eq(entries[3].ino, 3)
}

///|
test "we describe the same entries as GNU cpio" {
  // GNU cpio writes hexadecimal digits in upper case and pads the archive to
  // 512 bytes; librpm (and we) use lower case. So compare the entries and the
  // layout length instead of raw bytes.
  let reference = decode_fixture(ref_tree)
  assert_eq(@cpio.parse(reference), reference_entries())
  let mine = @cpio.build(reference_entries())
  let expected_length = (reference.length() + 511) / 512 * 512
  assert_eq(expected_length, 1024)
  let mut last_data = 0
  for i in 0..<reference.length() {
    if reference[i] != b'\x00' {
      last_data = i + 1
    }
  }
  // The padded trailer ends at the same 4-byte aligned place.
  assert_eq(mine.length(), (last_data + 1 + 3) / 4 * 4)
}

///|
test "build then parse is the identity" {
  let entries = [
    @cpio.Entry::dir("./usr", mtime=5L, ino=7),
    @cpio.Entry::file("./usr/é", b"x", uid=1000, gid=100, mtime=0xfffffffeL),
    @cpio.Entry::file("./empty", b""),
    @cpio.Entry::file("./big", Bytes::make(1001, b'q')),
    @cpio.Entry::symlink("./l", "../t"),
  ]
  assert_eq(@cpio.parse(@cpio.build(entries)), entries)
}

///|
test "records are 4-byte aligned" {
  for len in 0..<9 {
    let archive = @cpio.build([@cpio.Entry::file("./f", Bytes::make(len, b'a'))])
    assert_eq(archive.length() % 4, 0)
  }
}

///|
test "the trailer is TRAILER!!! with no links" {
  let archive = @cpio.build([])
  assert_eq(archive.length(), 112 + 12)
  assert_eq(@cpio.parse(archive).length(), 0)
}

///|
fn write_error(entry : @cpio.Entry) -> String {
  try @cpio.build([entry]) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "unrepresentable entries are rejected" {
  inspect(
    write_error(@cpio.Entry::file("", b"")),
    content="path: must not be empty",
  )
  inspect(
    write_error(@cpio.Entry::file("a\u{0}b", b"")),
    content="path: must not contain NUL",
  )
  inspect(
    write_error(@cpio.Entry::file("a", b"", mtime=4294967296L)),
    content="mtime: 4294967296 does not fit in 32 bits",
  )
  inspect(
    write_error(@cpio.Entry::file("a", b"", uid=-1)),
    content="uid: -1 does not fit in 32 bits",
  )
}

///|
fn parse_error(archive : BytesView) -> String {
  try @cpio.parse(archive) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
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
test "corrupt archives are reported with their offset" {
  let good = @cpio.build([@cpio.Entry::file("./f", b"abcd")])
  inspect(parse_error(good), content="ok")
  inspect(
    parse_error(b""),
    content="corrupt cpio at offset 0: truncated header (0 bytes left, no TRAILER!!!)",
  )
  inspect(
    parse_error(good[0:good.length() - 124]),
    content="corrupt cpio at offset 120: truncated header (0 bytes left, no TRAILER!!!)",
  )
  inspect(
    parse_error(mutate(good, b => b[5] = b'9')),
    content="corrupt cpio at offset 0: bad magic \"070709\", expected 070701",
  )
  inspect(
    parse_error(mutate(good, b => b[20] = b'g')),
    content="corrupt cpio at offset 0: mode is not hexadecimal",
  )
  // Claim a huge file size (bytes 54..62 of the first header).
  inspect(
    parse_error(
      mutate(good, b => {
        for i in 54..<62 {
          b[i] = b'f'
        }
      }),
    ),
    content="corrupt cpio at offset 0: entry declares 4294967295 bytes but only 128 remain",
  )
  // A name size that exceeds the archive.
  inspect(
    parse_error(
      mutate(good, b => {
        for i in 94..<102 {
          b[i] = b'f'
        }
      }),
    ),
    content="corrupt cpio at offset 0: name size 4294967295 does not fit the archive",
  )
  // A name that is not NUL terminated.
  inspect(
    parse_error(mutate(good, b => b[113] = b'x')),
    content="corrupt cpio at offset 0: file name is not NUL terminated",
  )
  inspect(
    parse_error(good[0:130]),
    content="corrupt cpio at offset 120: truncated header (10 bytes left, no TRAILER!!!)",
  )
}

///|
test "the number of entries is bounded" {
  let archive = @cpio.build([
    @cpio.Entry::file("./a", b""),
    @cpio.Entry::file("./b", b""),
  ])
  assert_eq(@cpio.parse(archive, max_entries=2).length(), 2)
  try @cpio.parse(archive, max_entries=1) catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt cpio at offset 116: more than 1 entries",
      )
  } noraise {
    _ => fail("expected an error")
  }
}
