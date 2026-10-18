///|
/// Size of a tar block; headers and data are padded to this.
const BLOCK_SIZE : Int32 = 512

///|
const NAME_SIZE : Int32 = 100

///|
const PREFIX_SIZE : Int32 = 155

///|
/// Everything that goes into one 512-byte ustar header.
priv struct Header {
  name : BytesView
  prefix : BytesView
  mode : Int32
  uid : Int32
  gid : Int32
  size : Int64
  mtime : Int64
  typeflag : Byte
  linkname : BytesView
  uname : BytesView
  gname : BytesView
}

///|
fn put_bytes(
  header : FixedArray[Byte],
  offset : Int32,
  src : BytesView,
) -> Unit {
  for i in 0..<src.length() {
    header[offset + i] = src[i]
  }
}

///|
/// Write `value` as `width - 1` zero-padded octal digits followed by NUL.
fn put_octal(
  header : FixedArray[Byte],
  offset : Int32,
  width : Int32,
  value : Int64,
  field : String,
) -> Unit raise TarError {
  if value < 0L {
    raise TarError::Invalid(field~, message="must not be negative")
  }
  let mut rest = value
  let mut i = width - 2
  while i >= 0 {
    header[offset + i] = (48 + (rest % 8L).to_int()).to_byte()
    rest = rest / 8L
    i -= 1
  }
  if rest != 0L {
    raise TarError::Invalid(
      field~,
      message="\{value} does not fit in \{width - 1} octal digits",
    )
  }
  header[offset + width - 1] = 0
}

///|
fn Header::encode(self : Header) -> Bytes raise TarError {
  let h : FixedArray[Byte] = FixedArray::make(BLOCK_SIZE, b'\x00')
  put_bytes(h, 0, self.name)
  put_octal(h, 100, 8, self.mode.to_int64(), "mode")
  put_octal(h, 108, 8, self.uid.to_int64(), "uid")
  put_octal(h, 116, 8, self.gid.to_int64(), "gid")
  put_octal(h, 124, 12, self.size, "size")
  put_octal(h, 136, 12, self.mtime, "mtime")
  h[156] = self.typeflag
  put_bytes(h, 157, self.linkname)
  put_bytes(h, 257, b"ustar\x00")
  put_bytes(h, 263, b"00")
  put_bytes(h, 265, self.uname)
  put_bytes(h, 297, self.gname)
  put_octal(h, 329, 8, 0L, "devmajor")
  put_octal(h, 337, 8, 0L, "devminor")
  put_bytes(h, 345, self.prefix)
  // The checksum is computed with its own field read as eight spaces.
  for i in 148..<156 {
    h[i] = b' '
  }
  let mut sum = 0
  for b in h {
    sum += b.to_int()
  }
  put_octal(h, 148, 7, sum.to_int64(), "checksum")
  h[155] = b' '
  Bytes::from_array(h[:])
}

///|
/// Cut `bytes` to at most `max` bytes without splitting a UTF-8 sequence.
fn truncate_utf8(bytes : Bytes, max : Int32) -> BytesView {
  if bytes.length() <= max {
    return bytes[:]
  }
  let mut cut = max
  while cut > 0 && (bytes[cut].to_int() & 0xC0) == 0x80 {
    cut -= 1
  }
  bytes[0:cut]
}

///|
/// Split a long name at a `/` so that the front fits the 155-byte ustar
/// prefix and the rest fits the 100-byte name field, preferring the longest
/// prefix (like GNU tar). Returns `None` when no such split exists.
fn split_name(name : Bytes) -> (BytesView, BytesView)? {
  let len = name.length()
  let mut i = if len - 2 < PREFIX_SIZE { len - 2 } else { PREFIX_SIZE }
  while i > 0 {
    if name[i] == b'/' && len - i - 1 <= NAME_SIZE {
      return Some((name[0:i], name[i + 1:]))
    }
    i -= 1
  }
  None
}

///|
fn decimal_digits(n : Int32) -> Int32 {
  let mut digits = 1
  let mut rest = n / 10
  while rest > 0 {
    digits += 1
    rest = rest / 10
  }
  digits
}

///|
/// One PAX record: `<length> <key>=<value>\n`, where the length counts the
/// whole record including its own digits.
fn pax_record(key : String, value : BytesView) -> Bytes {
  let key_bytes = @utf8.encode(key)
  let rest = 1 + key_bytes.length() + 1 + value.length() + 1
  let mut total = rest + 1
  while rest + decimal_digits(total) != total {
    total = rest + decimal_digits(total)
  }
  let out = Buffer(size_hint=total)
  out.write_bytes(@utf8.encode(total.to_string()))
  out.write_byte(b' ')
  out.write_bytes(key_bytes)
  out.write_byte(b'=')
  out.write_bytes(value)
  out.write_byte(b'\n')
  out.to_bytes()
}

///|
fn pad_to_block(out : Buffer, length : Int32) -> Unit {
  let remainder = length % BLOCK_SIZE
  if remainder != 0 {
    out.write_bytes(Bytes::make(BLOCK_SIZE - remainder, b'\x00'))
  }
}

///|
/// The last path component, used to name the PAX header of an entry.
fn base_name(path : Bytes) -> BytesView {
  let mut end = path.length()
  while end > 0 && path[end - 1] == b'/' {
    end -= 1
  }
  let mut start = end
  while start > 0 && path[start - 1] != b'/' {
    start -= 1
  }
  path[start:end]
}

///|
fn check_text(
  field : String,
  bytes : Bytes,
  max : Int32,
  allow_empty : Bool,
) -> Unit raise TarError {
  if bytes.length() == 0 && !allow_empty {
    raise TarError::Invalid(field~, message="must not be empty")
  }
  if bytes.length() > max {
    raise TarError::Invalid(
      field~,
      message="is \{bytes.length()} bytes long, at most \{max} fit",
    )
  }
  for b in bytes {
    if b == b'\x00' {
      raise TarError::Invalid(field~, message="must not contain NUL")
    }
  }
}

///|
/// A PAX extended header (`x`) carrying the records that did not fit.
fn write_pax_header(
  out : Buffer,
  records : Array[Bytes],
  name : Bytes,
  mtime : Int64,
) -> Unit raise TarError {
  let data = Buffer()
  for record in records {
    data.write_bytes(record)
  }
  let pax_name = @utf8.encode("PaxHeaders/")
  let header = {
    name: truncate_utf8(
      Bytes::from_array([..pax_name, ..base_name(name)]),
      NAME_SIZE,
    ),
    prefix: b""[:],
    mode: 0o644,
    uid: 0,
    gid: 0,
    size: data.length().to_int64(),
    mtime,
    typeflag: b'x',
    linkname: b""[:],
    uname: b""[:],
    gname: b""[:],
  }
  out.write_bytes(header.encode())
  out.write_bytes(data.to_bytes())
  pad_to_block(out, data.length())
}

///|
/// A GNU long name (`L`) or long link (`K`) pseudo entry: a header named
/// `././@LongLink` whose data is the NUL terminated value.
fn write_gnu_long(
  out : Buffer,
  typeflag : Byte,
  value : Bytes,
) -> Unit raise TarError {
  let data = Bytes::from_array([..value, b'\x00'])
  let header = {
    name: b"././@LongLink"[:],
    prefix: b""[:],
    mode: 0,
    uid: 0,
    gid: 0,
    size: data.length().to_int64(),
    mtime: 0L,
    typeflag,
    linkname: b""[:],
    uname: b""[:],
    gname: b""[:],
  }
  out.write_bytes(header.encode())
  out.write_bytes(data)
  pad_to_block(out, data.length())
}

///|
fn write_entry(
  out : Buffer,
  entry : Entry,
  long_names : LongNames,
) -> Unit raise TarError {
  let mut name = @utf8.encode(entry.path)
  check_text("path", name, 1 << 20, false)
  if entry.kind is Dir && name[name.length() - 1] != b'/' {
    name = Bytes::from_array([..name, b'/'])
  }
  let uname = @utf8.encode(entry.uname)
  let gname = @utf8.encode(entry.gname)
  check_text("uname", uname, 31, true)
  check_text("gname", gname, 31, true)
  if entry.mode < 0 || entry.mode > 0o7777 {
    raise TarError::Invalid(
      field="mode",
      message="must be between 0 and 07777, got \{entry.mode.to_string(radix=8)}",
    )
  }
  let (typeflag, link, content) = match entry.kind {
    File(content) => (b'0', b"", content)
    Dir => (b'5', b"", b"")
    Symlink(target) => {
      let link = @utf8.encode(target)
      check_text("link target", link, 1 << 20, false)
      (b'2', link, b"")
    }
    Hardlink(target) => {
      let link = @utf8.encode(target)
      check_text("link target", link, 1 << 20, false)
      (b'1', link, b"")
    }
    Special(_) =>
      raise TarError::Invalid(
        field="kind",
        message="special files cannot be written",
      )
  }
  let mut name_overflows = false
  let (prefix, short_name) = if name.length() <= NAME_SIZE {
    (b""[:], name[:])
  } else {
    match split_name(name) {
      Some(parts) => parts
      None => {
        name_overflows = true
        (b""[:], truncate_utf8(name, NAME_SIZE))
      }
    }
  }
  let link_overflows = link.length() > NAME_SIZE
  let link_field = if link_overflows {
    truncate_utf8(link, NAME_SIZE)
  } else {
    link[:]
  }
  match long_names {
    Pax => {
      let records : Array[Bytes] = []
      if name_overflows {
        records.push(pax_record("path", name))
      }
      if link_overflows {
        records.push(pax_record("linkpath", link))
      }
      if records.length() > 0 {
        write_pax_header(out, records, name, entry.mtime)
      }
    }
    Gnu => {
      if link_overflows {
        write_gnu_long(out, b'K', link)
      }
      if name_overflows {
        write_gnu_long(out, b'L', name)
      }
    }
  }
  let header = {
    name: short_name,
    prefix,
    mode: entry.mode,
    uid: entry.uid,
    gid: entry.gid,
    size: content.length().to_int64(),
    mtime: entry.mtime,
    typeflag,
    linkname: link_field,
    uname: uname[:],
    gname: gname[:],
  }
  out.write_bytes(header.encode())
  out.write_bytes(content)
  pad_to_block(out, content.length())
}

///|
/// Serialize entries into a ustar archive. The output depends only on the
/// entries, so building the same list twice gives identical bytes.
///
/// Names longer than 100 bytes are split into the ustar prefix when possible.
/// Otherwise, and for long link targets, `long_names` chooses the encoding:
/// PAX extended headers (the default, understood by GNU tar, libarchive and
/// Python) or GNU `L`/`K` entries (the only form `dpkg` can unpack). The
/// archive ends with two zero blocks.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @tar.build([@tar.Entry::file("./hello.txt", b"hi\n")])
///   // header + one data block + two end-of-archive blocks
///   assert_eq(archive.length(), 4 * 512)
/// }
/// ```
pub fn build(
  entries : Array[Entry],
  long_names~ : LongNames = Pax,
) -> Bytes raise TarError {
  let out = Buffer(size_hint=4096)
  for entry in entries {
    write_entry(out, entry, long_names)
  }
  out.write_bytes(Bytes::make(2 * BLOCK_SIZE, b'\x00'))
  out.to_bytes()
}
