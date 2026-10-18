///|
fn pax_header_for(data : Bytes) -> Bytes raise TarError {
  let header : Header = {
    name: b"PaxHeaders/x"[:],
    prefix: b""[:],
    mode: 0o644,
    uid: 0,
    gid: 0,
    size: data.length().to_int64(),
    mtime: 0L,
    typeflag: b'x',
    linkname: b""[:],
    uname: b""[:],
    gname: b""[:],
  }
  let out = Buffer()
  out.write_bytes(header.encode())
  out.write_bytes(data)
  pad_to_block(out, data.length())
  out.to_bytes()
}

///|
fn plain_file_header(size : Int64, typeflag : Byte) -> Bytes raise TarError {
  let header : Header = {
    name: b"./f"[:],
    prefix: b""[:],
    mode: 0o600,
    uid: 7,
    gid: 8,
    size,
    mtime: 99L,
    typeflag,
    linkname: b""[:],
    uname: b"bob"[:],
    gname: b"users"[:],
  }
  header.encode()
}

///|
fn archive_with_pax(records : String, data : Bytes) -> Bytes raise TarError {
  let out = Buffer()
  out.write_bytes(pax_header_for(@utf8.encode(records)))
  out.write_bytes(plain_file_header(0L, b'0'))
  out.write_bytes(data)
  pad_to_block(out, data.length())
  out.write_bytes(Bytes::make(1024, b'\x00'))
  out.to_bytes()
}

///|
fn pax_text(key : String, value : String) -> String {
  let rest = 1 + key.length() + 1 + value.length() + 1
  let mut total = rest + 1
  while rest + decimal_digits(total) != total {
    total = rest + decimal_digits(total)
  }
  "\{total} \{key}=\{value}\n"
}

///|
test "PAX records override the ustar fields of the next entry" {
  let records = pax_text("uid", "1000") +
    pax_text("gid", "100") +
    pax_text("mtime", "1700000000.25") +
    pax_text("uname", "alice") +
    pax_text("gname", "staff") +
    pax_text("size", "3") +
    pax_text("path", "./renamed") +
    pax_text("comment", "ignored")
  let entries = parse(archive_with_pax(records, b"abc"))
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "./renamed")
  assert_eq(entries[0].kind, EntryKind::File(b"abc"))
  assert_eq(entries[0].uid, 1000)
  assert_eq(entries[0].gid, 100)
  assert_eq(entries[0].mtime, 1700000000L)
  assert_eq(entries[0].uname, "alice")
  assert_eq(entries[0].gname, "staff")
  assert_eq(entries[0].mode, 0o600)
}

///|
test "PAX overrides do not leak into the following entry" {
  let out = Buffer()
  out.write_bytes(pax_header_for(@utf8.encode(pax_text("uid", "1000"))))
  out.write_bytes(plain_file_header(0L, b'0'))
  out.write_bytes(plain_file_header(0L, b'0'))
  out.write_bytes(Bytes::make(1024, b'\x00'))
  let entries = parse(out.to_bytes())
  assert_eq(entries.map(e => e.uid), [1000, 7])
}

///|
fn pax_error(records : String) -> String {
  try parse(archive_with_pax(records, b"")) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "malformed PAX records" {
  inspect(
    pax_error("junk"),
    content="corrupt tar at offset 0: bad PAX record length",
  )
  inspect(pax_error("6 a=b\n"), content="ok")
  inspect(
    pax_error("99 a=b\n"),
    content="corrupt tar at offset 0: PAX record of 99 bytes does not fit its header",
  )
  inspect(
    pax_error("6 a=b!"),
    content="corrupt tar at offset 0: PAX record has no newline",
  )
  inspect(
    pax_error("5 ab\n"),
    content="corrupt tar at offset 0: PAX record has no '='",
  )
  inspect(
    pax_error("12 uid=nope\n"),
    content="corrupt tar at offset 0: PAX uid is not a number",
  )
  inspect(
    pax_error("10 uid=-1\n"),
    content="corrupt tar at offset 1024: uid is out of range",
  )
}
