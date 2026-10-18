///|
fn hex_value(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    _ => abort("bad hex digit in fixture")
  }
}

///|
/// Decode a fixture: whitespace separated tokens, each either `Z<count>`
/// (that many zero bytes) or a run of hex digits.
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
/// Read a NUL terminated string field out of an archive.
fn text_at(archive : Bytes, offset : Int32, size : Int32) -> String {
  let out : Array[Byte] = []
  for i in offset..<(offset + size) {
    if archive[i] == b'\x00' {
      break
    }
    out.push(archive[i])
  }
  @utf8.decode_lossy(Bytes::from_array(out[:]))
}

///|
test "output matches GNU tar byte for byte" {
  let archive = @tar.build([
    @tar.Entry::dir("./usr/", mtime=1700000000L),
    @tar.Entry::file("./usr/hello", b"hi\n", mtime=1700000000L),
    @tar.Entry::symlink("./usr/hi", "hello", mtime=1700000000L),
    @tar.Entry::file("./usr/run", b"#!/bin/sh\n", mode=0o755, mtime=1700000000L),
  ])
  assert_eq(archive, decode_fixture(ref_tree))
}

///|
test "long names use the ustar prefix exactly like GNU tar" {
  let dir = "d".repeat(60) + "/" + "e".repeat(60)
  let archive = @tar.build([
    @tar.Entry::file("./\{dir}/file.txt", b"x", mtime=1700000000L),
  ])
  assert_eq(archive, decode_fixture(ref_long_prefix))
}

///|
test "directories get a trailing slash" {
  let archive = @tar.build([@tar.Entry::dir("./usr/bin")])
  assert_eq(text_at(archive, 0, 100), "./usr/bin/")
  assert_eq(archive[156], b'5')
}

///|
test "output is deterministic and block aligned" {
  let entries = [
    @tar.Entry::dir("./etc/"),
    @tar.Entry::file("./etc/motd", Bytes::make(513, b'm')),
  ]
  let first = @tar.build(entries)
  let second = @tar.build(entries)
  assert_eq(first, second)
  // dir header + file header + 2 data blocks + 2 end blocks
  assert_eq(first.length(), 6 * 512)
  assert_eq(first.length() % 512, 0)
}

///|
test "an empty archive is two zero blocks" {
  assert_eq(@tar.build([]), Bytes::make(1024, b'\x00'))
}

///|
test "a name of exactly 100 bytes stays in the name field" {
  let name = "./" + "n".repeat(98)
  let archive = @tar.build([@tar.Entry::file(name, b"")])
  assert_eq(text_at(archive, 0, 100), name)
  assert_eq(text_at(archive, 345, 155), "")
  assert_eq(archive.length(), 512 + 1024)
}

///|
test "names too long for the prefix use a PAX header" {
  let path = "./" + "p".repeat(150) + "/" + "q".repeat(150)
  let archive = @tar.build([@tar.Entry::file(path, b"data")])
  // PAX header + its data block + file header + data block + end of archive
  assert_eq(archive.length(), 4 * 512 + 1024)
  assert_eq(archive[156], b'x')
  assert_eq(text_at(archive, 0, 100), "PaxHeaders/" + "q".repeat(89))
  // 6 bytes " path=", 303 bytes of path, 1 newline and 3 digits of length.
  let record = "313 path=\{path}\n"
  assert_eq(text_at(archive, 512, 512), record)
  assert_eq(text_at(archive, 124, 12), "00000000471") // 313 bytes of records
  assert_eq(archive[1024 + 156], b'0')
  assert_eq(text_at(archive, 1024, 100), path[0:100].to_owned())
}

///|
test "long link targets use a PAX header" {
  let target = "../" + "t".repeat(200)
  let archive = @tar.build([@tar.Entry::symlink("./usr/link", target)])
  assert_eq(archive[156], b'x')
  // 10 bytes " linkpath=", 203 bytes of target, 1 newline and 3 digits of length.
  assert_eq(text_at(archive, 512, 512), "217 linkpath=\{target}\n")
  assert_eq(archive[1024 + 156], b'2')
  assert_eq(text_at(archive, 1024 + 157, 100), target[0:100].to_owned())
  assert_eq(text_at(archive, 1024, 100), "./usr/link")
}

///|
test "PAX values are cut on UTF-8 boundaries" {
  // 'é' is two bytes, so 200 of them are 400 bytes; no split point exists
  // because there is no '/' except the leading "./".
  let name = "./" + "é".repeat(200)
  let archive = @tar.build([@tar.Entry::file(name, b"")])
  assert_eq(archive[156], b'x')
  let main_name = text_at(archive, 1024, 100)
  // 98 bytes after "./" are 49 whole characters, never half of one.
  assert_eq(main_name, "./" + "é".repeat(49))
  assert_eq(main_name.length(), 51)
}

///|
test "invalid input is rejected with the offending field" {
  fn failure(entry : @tar.Entry) -> String {
    try @tar.build([entry]) catch {
      err => "\{err}"
    } noraise {
      _ => "ok"
    }
  }

  inspect(failure(@tar.Entry::file("", b"")), content="path: must not be empty")
  inspect(
    failure(@tar.Entry::file("./a\u{0}b", b"")),
    content="path: must not contain NUL",
  )
  inspect(
    failure(@tar.Entry::symlink("./l", "")),
    content="link target: must not be empty",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", uname="u".repeat(32))),
    content="uname: is 32 bytes long, at most 31 fit",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", mode=0o10000)),
    content="mode: must be between 0 and 07777, got 10000",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", mtime=-1L)),
    content="mtime: must not be negative",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", mtime=8589934592L)),
    content="mtime: 8589934592 does not fit in 11 octal digits",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", uid=2097152)),
    content="uid: 2097152 does not fit in 7 octal digits",
  )
  inspect(
    failure(@tar.Entry::file("./f", b"", gid=-1)),
    content="gid: must not be negative",
  )
}
