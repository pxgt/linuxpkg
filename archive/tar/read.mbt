///|
/// Bytes up to (not including) the first NUL.
fn c_string(bytes : BytesView) -> BytesView {
  let mut end = 0
  while end < bytes.length() && bytes[end] != b'\x00' {
    end += 1
  }
  bytes[0:end]
}

///|
fn is_zero_block(block : BytesView) -> Bool {
  for b in block {
    if b != b'\x00' {
      return false
    }
  }
  true
}

///|
/// Read a numeric header field: octal ASCII, or the GNU base-256 form used
/// when a value does not fit (high bit of the first byte set).
fn read_number(
  block : BytesView,
  offset : Int32,
  width : Int32,
  field : String,
  at : Int32,
) -> Int64 raise TarError {
  let first = block[offset].to_int()
  if (first & 0x80) != 0 {
    let mut value = (first & 0x7f).to_int64()
    for i in 1..<width {
      if value > 0x007fffffffffffffL {
        raise TarError::Corrupt(offset=at, message="\{field} is too large")
      }
      value = value * 256L + block[offset + i].to_int().to_int64()
    }
    return value
  }
  let mut i = 0
  while i < width && block[offset + i] == b' ' {
    i += 1
  }
  let mut value = 0L
  while i < width {
    let b = block[offset + i]
    if b == b'\x00' || b == b' ' {
      break
    }
    if b < b'0' || b > b'7' {
      raise TarError::Corrupt(
        offset=at,
        message="\{field} contains a byte that is not an octal digit",
      )
    }
    if value > 0x0fffffffffffffffL {
      raise TarError::Corrupt(offset=at, message="\{field} is too large")
    }
    value = value * 8L + (b.to_int() - 48).to_int64()
    i += 1
  }
  value
}

///|
fn check_checksum(block : BytesView, at : Int32) -> Unit raise TarError {
  let stored = read_number(block, 148, 8, "checksum", at)
  let mut unsigned = 0L
  let mut signed = 0L
  for i in 0..<BLOCK_SIZE {
    let b = if i >= 148 && i < 156 { 32 } else { block[i].to_int() }
    unsigned += b.to_int64()
    signed += (if b >= 128 { b - 256 } else { b }).to_int64()
  }
  if stored != unsigned && stored != signed {
    raise TarError::Corrupt(
      offset=at,
      message="header checksum is \{stored}, expected \{unsigned}",
    )
  }
}

///|
/// Decimal number in a PAX value; a fractional part is dropped.
fn pax_number(
  value : BytesView,
  key : String,
  at : Int32,
) -> Int64 raise TarError {
  let mut i = 0
  let mut negative = false
  if value.length() > 0 && value[0] == b'-' {
    negative = true
    i = 1
  }
  if i >= value.length() {
    raise TarError::Corrupt(offset=at, message="PAX \{key} is empty")
  }
  let mut n = 0L
  while i < value.length() && value[i] != b'.' {
    let b = value[i]
    if b < b'0' || b > b'9' || n > 0x0fffffffffffffL {
      raise TarError::Corrupt(offset=at, message="PAX \{key} is not a number")
    }
    n = n * 10L + (b.to_int() - 48).to_int64()
    i += 1
  }
  if negative {
    -n
  } else {
    n
  }
}

///|
/// Values a PAX extended header overrides for the next entry.
priv struct Overrides {
  mut path : Bytes?
  mut link : Bytes?
  mut size : Int64?
  mut uid : Int64?
  mut gid : Int64?
  mut mtime : Int64?
  mut uname : Bytes?
  mut gname : Bytes?
  /// Records this reader has no use for (`APK-TOOLS.checksum.SHA1`, ...).
  extra : Array[(String, String)]
}

///|
fn Overrides::new() -> Overrides {
  {
    path: None,
    link: None,
    size: None,
    uid: None,
    gid: None,
    mtime: None,
    uname: None,
    gname: None,
    extra: [],
  }
}

///|
/// Apply the `<length> <key>=<value>\n` records of a PAX header.
fn apply_pax(
  data : BytesView,
  overrides : Overrides,
  at : Int32,
) -> Unit raise TarError {
  let mut pos = 0
  while pos < data.length() {
    let mut len = 0
    let mut i = pos
    while i < data.length() && data[i] >= b'0' && data[i] <= b'9' {
      if len > 100000000 {
        raise TarError::Corrupt(offset=at, message="PAX record is too long")
      }
      len = len * 10 + (data[i].to_int() - 48)
      i += 1
    }
    if i == pos || i >= data.length() || data[i] != b' ' {
      raise TarError::Corrupt(offset=at, message="bad PAX record length")
    }
    if len < i - pos + 4 || pos + len > data.length() {
      raise TarError::Corrupt(
        offset=at,
        message="PAX record of \{len} bytes does not fit its header",
      )
    }
    if data[pos + len - 1] != b'\n' {
      raise TarError::Corrupt(offset=at, message="PAX record has no newline")
    }
    let record = data[i + 1:pos + len - 1]
    let mut eq = 0
    while eq < record.length() && record[eq] != b'=' {
      eq += 1
    }
    if eq == record.length() {
      raise TarError::Corrupt(offset=at, message="PAX record has no '='")
    }
    let key = @utf8.decode_lossy(record[0:eq])
    let value = record[eq + 1:]
    match key {
      "path" => overrides.path = Some(value.to_owned())
      "linkpath" => overrides.link = Some(value.to_owned())
      "size" => overrides.size = Some(pax_number(value, key, at))
      "uid" => overrides.uid = Some(pax_number(value, key, at))
      "gid" => overrides.gid = Some(pax_number(value, key, at))
      "mtime" => overrides.mtime = Some(pax_number(value, key, at))
      "uname" => overrides.uname = Some(value.to_owned())
      "gname" => overrides.gname = Some(value.to_owned())
      _ => overrides.extra.push((key, @utf8.decode_lossy(value)))
    }
    pos += len
  }
}

///|
fn to_int_checked(
  value : Int64,
  field : String,
  at : Int32,
) -> Int32 raise TarError {
  if value < 0L || value > 2147483647L {
    raise TarError::Corrupt(offset=at, message="\{field} is out of range")
  }
  value.to_int()
}

///|
/// Parse a tar archive in ustar, GNU or PAX form.
///
/// GNU `L`/`K` long names and PAX `path`, `linkpath`, `size`, `uid`, `gid`,
/// `mtime`, `uname` and `gname` records are applied to the entry that follows
/// them. Global PAX headers are skipped. A missing end-of-archive marker is
/// tolerated, a corrupt header (bad checksum, bad number, truncated data) is
/// reported with its byte offset.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @tar.build([@tar.Entry::file("./hello.txt", b"hi\n")])
///   let entries = @tar.parse(archive)
///   assert_eq(entries.length(), 1)
///   assert_eq(entries[0].path, "./hello.txt")
///   assert_eq(entries[0].kind, @tar.EntryKind::File(b"hi\n"))
/// }
/// ```
pub fn parse(
  archive : BytesView,
  max_entries~ : Int32 = 1000000,
) -> Array[Entry] raise TarError {
  parse_with_records(archive, max_entries~).map(item => item.0)
}

///|
/// Like `parse`, and also returns the PAX records of each entry that the
/// reader itself does not interpret (everything but `path`, `linkpath`,
/// `size`, `uid`, `gid`, `mtime`, `uname` and `gname`), for example Alpine's
/// `APK-TOOLS.checksum.SHA1`.
pub fn parse_with_records(
  archive : BytesView,
  max_entries~ : Int32 = 1000000,
) -> Array[(Entry, Array[(String, String)])] raise TarError {
  let entries : Array[(Entry, Array[(String, String)])] = []
  let overrides = Overrides::new()
  let mut gnu_path : Bytes? = None
  let mut gnu_link : Bytes? = None
  let mut pos = 0
  while pos + BLOCK_SIZE <= archive.length() {
    let block = archive[pos:pos + BLOCK_SIZE]
    if is_zero_block(block) {
      break
    }
    check_checksum(block, pos)
    let typeflag = block[156]
    let declared = read_number(block, 124, 12, "size", pos)
    let size = match overrides.size {
      Some(s) if typeflag != b'x' && typeflag != b'g' => s
      _ => declared
    }
    // Only these types carry data; for the others the size field is ignored.
    let has_data = match typeflag {
      b'0' | b'\x00' | b'7' | b'x' | b'g' | b'L' | b'K' => true
      _ => false
    }
    let data_len = if has_data { size } else { 0L }
    let data_start = pos + BLOCK_SIZE
    if data_len > (archive.length() - data_start).to_int64() {
      raise TarError::Corrupt(
        offset=pos,
        message="entry declares \{data_len} bytes but only \{archive.length() - data_start} remain",
      )
    }
    let data = archive[data_start:data_start + data_len.to_int()]
    let padded = (data_len.to_int() + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE
    let next = data_start + padded
    match typeflag {
      b'x' => apply_pax(data, overrides, pos)
      b'g' => ()
      b'L' => gnu_path = Some(c_string(data).to_owned())
      b'K' => gnu_link = Some(c_string(data).to_owned())
      _ => {
        if entries.length() >= max_entries {
          raise TarError::Corrupt(
            offset=pos,
            message="more than \{max_entries} entries",
          )
        }
        let mut name = c_string(block[0:100]).to_owned()
        let has_prefix = block[257:263] == b"ustar\x00"[:]
        if has_prefix {
          let prefix = c_string(block[345:500])
          if prefix.length() > 0 {
            name = Bytes::from_array([..prefix, b'/', ..name])
          }
        }
        if gnu_path is Some(p) {
          name = p
        }
        if overrides.path is Some(p) {
          name = p
        }
        let mut link = c_string(block[157:257]).to_owned()
        if gnu_link is Some(l) {
          link = l
        }
        if overrides.link is Some(l) {
          link = l
        }
        let kind = match typeflag {
          b'0' | b'\x00' | b'7' => File(data.to_owned())
          b'5' => Dir
          b'2' => Symlink(@utf8.decode_lossy(link))
          b'1' => Hardlink(@utf8.decode_lossy(link))
          other => Special(other.to_int())
        }
        let uname = match overrides.uname {
          Some(u) => u
          None => c_string(block[265:297]).to_owned()
        }
        let gname = match overrides.gname {
          Some(g) => g
          None => c_string(block[297:329]).to_owned()
        }
        let uid = match overrides.uid {
          Some(v) => v
          None => read_number(block, 108, 8, "uid", pos)
        }
        let gid = match overrides.gid {
          Some(v) => v
          None => read_number(block, 116, 8, "gid", pos)
        }
        let mtime = match overrides.mtime {
          Some(v) => v
          None => read_number(block, 136, 12, "mtime", pos)
        }
        let entry : Entry = {
          path: @utf8.decode_lossy(name),
          kind,
          mode: (read_number(block, 100, 8, "mode", pos) & 0o7777L).to_int(),
          uid: to_int_checked(uid, "uid", pos),
          gid: to_int_checked(gid, "gid", pos),
          uname: @utf8.decode_lossy(uname),
          gname: @utf8.decode_lossy(gname),
          mtime,
        }
        entries.push((entry, overrides.extra.copy()))
        overrides.extra.clear()
        // Extensions apply to one entry only.
        gnu_path = None
        gnu_link = None
        overrides.path = None
        overrides.link = None
        overrides.size = None
        overrides.uid = None
        overrides.gid = None
        overrides.mtime = None
        overrides.uname = None
        overrides.gname = None
      }
    }
    pos = next
  }
  if gnu_path is Some(_) ||
    gnu_link is Some(_) ||
    overrides.path is Some(_) ||
    overrides.link is Some(_) {
    raise TarError::Corrupt(
      offset=pos,
      message="a long name header is not followed by an entry",
    )
  }
  if pos < archive.length() && pos + BLOCK_SIZE > archive.length() {
    // Fewer than 512 bytes are left: only zero padding is acceptable.
    if !is_zero_block(archive[pos:]) {
      raise TarError::Corrupt(
        offset=pos,
        message="truncated header (\{archive.length() - pos} bytes left)",
      )
    }
  }
  entries
}
