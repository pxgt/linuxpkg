///|
/// Build one raw member header by hand, independent of the writer.
fn raw_header(
  name : String,
  mtime~ : String = "0",
  uid~ : String = "0",
  gid~ : String = "0",
  mode~ : String = "100644",
  size~ : String,
) -> String {
  fn pad(text : String, width : Int32) -> String {
    text + " ".repeat(width - text.length())
  }

  pad(name, 16) +
  pad(mtime, 12) +
  pad(uid, 6) +
  pad(gid, 6) +
  pad(mode, 8) +
  pad(size, 10) +
  "`\n"
}

///|
fn bytes_of(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
test "writer output matches the documented layout" {
  let archive = @ar.build([
    @ar.Member::new("hello.txt", b"hello", mtime=1700000000L),
    @ar.Member::new("b", b"x"),
  ])
  let expected = "!<arch>\n" +
    raw_header("hello.txt", mtime="1700000000", size="5") +
    "hello\n" +
    raw_header("b", size="1") +
    "x\n"
  assert_eq(archive, bytes_of(expected))
  assert_eq(archive.length(), 136)
}

///|
test "a deb style archive" {
  let archive = @ar.build([
    @ar.Member::new("debian-binary", b"2.0\n"),
    @ar.Member::new("control.tar.gz", b"CCC"),
    @ar.Member::new("data.tar.gz", b"DDDD"),
  ])
  let expected = "!<arch>\n" +
    raw_header("debian-binary", size="4") +
    "2.0\n" +
    raw_header("control.tar.gz", size="3") +
    "CCC\n" +
    raw_header("data.tar.gz", size="4") +
    "DDDD"
  assert_eq(archive, bytes_of(expected))
}

///|
test "parse is the inverse of build" {
  let members = [
    @ar.Member::new("one", b"", mtime=5L, uid=1000, gid=100, mode=0o100755),
    @ar.Member::new("two.bin", b"\x00\x01\x02", mtime=1700000000L),
    @ar.Member::new("sixteen-chars-ok", Bytes::make(1001, b'z')),
  ]
  let parsed = @ar.parse(@ar.build(members))
  assert_eq(parsed, members)
}

///|
test "an empty archive has no members" {
  let archive = @ar.build([])
  assert_eq(archive, b"!<arch>\n")
  assert_eq(@ar.parse(archive).length(), 0)
}

///|
test "GNU style names with a trailing slash" {
  let archive = bytes_of(
    "!<arch>\n" + raw_header("hello.txt/", size="5") + "hello\n",
  )
  let members = @ar.parse(archive)
  assert_eq(members.length(), 1)
  assert_eq(members[0].name, "hello.txt")
  assert_eq(members[0].data, b"hello")
}

///|
test "GNU long names and the symbol table" {
  let table = "a_very_long_member_name.o/\nanother_long_name.o/\n"
  let archive = bytes_of(
    "!<arch>\n" +
    raw_header("/", size="4") +
    "SYMS" +
    raw_header("//", size=table.length().to_string()) +
    table +
    raw_header("/0", size="2") +
    "AA" +
    raw_header("/27", size="3") +
    "BBB\n",
  )
  let members = @ar.parse(archive)
  assert_eq(members.map(m => m.name), [
    "a_very_long_member_name.o", "another_long_name.o",
  ])
  assert_eq(members[0].data, b"AA")
  assert_eq(members[1].data, b"BBB")
}

///|
test "BSD long names" {
  let long = "a_name_longer_than_sixteen.txt"
  let archive = bytes_of(
    "!<arch>\n" +
    raw_header("#1/\{long.length()}", size="\{long.length() + 3}") +
    long +
    "abc\n",
  )
  let members = @ar.parse(archive)
  assert_eq(members.length(), 1)
  assert_eq(members[0].name, long)
  assert_eq(members[0].data, b"abc")
}

///|
test "a missing final padding byte is tolerated" {
  let archive = bytes_of("!<arch>\n" + raw_header("odd", size="3") + "xyz")
  let members = @ar.parse(archive)
  assert_eq(members.length(), 1)
  assert_eq(members[0].data, b"xyz")
}

///|
test "blank numeric fields read as zero" {
  let archive = bytes_of(
    "!<arch>\n" +
    raw_header("blank", mtime="", uid="", gid="", mode="", size="0"),
  )
  let members = @ar.parse(archive)
  assert_eq(members[0].mtime, 0L)
  assert_eq(members[0].uid, 0)
  assert_eq(members[0].mode, 0)
}

///|
fn parse_error(archive : Bytes) -> String {
  try @ar.parse(archive) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "corrupt archives are rejected with a position" {
  inspect(
    parse_error(b""),
    content="corrupt ar at offset 0: missing \"!<arch>\" signature",
  )
  inspect(
    parse_error(b"!<arch?\n"),
    content="corrupt ar at offset 0: missing \"!<arch>\" signature",
  )
  inspect(
    parse_error(bytes_of("!<arch>\nshort")),
    content="corrupt ar at offset 8: truncated member header (5 bytes left)",
  )
  let bad_end = raw_header("x", size="0").to_array()
  bad_end[58] = '!'
  inspect(
    parse_error(bytes_of("!<arch>\n" + String::from_array(bad_end))),
    content="corrupt ar at offset 8: member header does not end with \"`\\n\"",
  )
  inspect(
    parse_error(bytes_of("!<arch>\n" + raw_header("x", size="100") + "short")),
    content="corrupt ar at offset 8: member declares 100 bytes but only 5 remain",
  )
  inspect(
    parse_error(bytes_of("!<arch>\n" + raw_header("x", size="1x"))),
    content="corrupt ar at offset 8: size field contains a non-digit byte",
  )
  inspect(
    parse_error(bytes_of("!<arch>\n" + raw_header("x", mode="1089", size="0"))),
    content="corrupt ar at offset 8: mode field contains a non-digit byte",
  )
  inspect(
    parse_error(bytes_of("!<arch>\n" + raw_header("/99", size="0"))),
    content="corrupt ar at offset 8: long name reference 99 is outside the name table",
  )
  inspect(
    parse_error(bytes_of("!<arch>\n" + raw_header("#1/50", size="4") + "abcd")),
    content="corrupt ar at offset 8: BSD long name is longer than its member",
  )
}

///|
test "the member count is bounded" {
  let members = [
    @ar.Member::new("a", b""),
    @ar.Member::new("b", b""),
    @ar.Member::new("c", b""),
  ]
  let archive = @ar.build(members)
  assert_eq(@ar.parse(archive, max_members=3).length(), 3)
  try @ar.parse(archive, max_members=2) catch {
    err =>
      inspect("\{err}", content="corrupt ar at offset 128: more than 2 members")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "writer rejects members it cannot represent" {
  fn failure(item : @ar.Member) -> String {
    try @ar.build([item]) catch {
      err => "\{err}"
    } noraise {
      _ => "ok"
    }
  }

  inspect(failure(@ar.Member::new("", b"")), content="name: must not be empty")
  inspect(
    failure(@ar.Member::new("a_name_that_is_far_too_long", b"")),
    content="name: \"a_name_that_is_far_too_long\" is 27 bytes long, at most 16 fit",
  )
  inspect(
    failure(@ar.Member::new("dir/file", b"")),
    content="name: \"dir/file\" must not contain '/' or control characters",
  )
  inspect(
    failure(@ar.Member::new("tab\there", b"")),
    content="name: \"tab\there\" must not contain '/' or control characters",
  )
  inspect(
    failure(@ar.Member::new("trail ", b"")),
    content="name: \"trail \" must not end with a space",
  )
  inspect(
    failure(@ar.Member::new("a", b"", mtime=-1L)),
    content="mtime: must not be negative",
  )
  inspect(
    failure(@ar.Member::new("a", b"", uid=1000000)),
    content="uid: 1000000 does not fit in 6 characters",
  )
  inspect(
    failure(@ar.Member::new("a", b"", mode=0o1000000000)),
    content="mode: 1000000000 does not fit in 8 characters",
  )
}
