///|
fn hex_field(
  data : BytesView,
  offset : Int32,
  at : Int32,
  field : String,
) -> Int64 raise CpioError {
  let mut value = 0L
  for i in 0..<8 {
    let b = data[offset + i].to_int()
    let digit = if b >= 48 && b <= 57 {
      b - 48
    } else if b >= 97 && b <= 102 {
      b - 87
    } else if b >= 65 && b <= 70 {
      b - 55
    } else {
      raise CpioError::Corrupt(offset=at, message="\{field} is not hexadecimal")
    }
    value = value * 16L + digit.to_int64()
  }
  value
}

///|
/// Parse a `newc` (`070701`) or `crc` (`070702`) archive up to its
/// `TRAILER!!!` record. The checksum of `crc` archives is not verified.
/// `max_entries` bounds the work done on hostile input.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @cpio.build([@cpio.Entry::file("./a", b"xyz")])
///   let entries = @cpio.parse(archive)
///   assert_eq(entries.length(), 1)
///   assert_eq(entries[0].data, b"xyz")
/// }
/// ```
pub fn parse(
  archive : BytesView,
  max_entries~ : Int32 = 1000000,
) -> Array[Entry] raise CpioError {
  let entries : Array[Entry] = []
  let mut pos = 0
  while true {
    if archive.length() - pos < HEADER_SIZE {
      raise CpioError::Corrupt(
        offset=pos,
        message="truncated header (\{archive.length() - pos} bytes left, no TRAILER!!!)",
      )
    }
    let magic = @utf8.decode_lossy(archive[pos:pos + 6])
    if magic != MAGIC && magic != "070702" {
      raise CpioError::Corrupt(
        offset=pos,
        message="bad magic \"\{magic}\", expected 070701",
      )
    }
    let at = pos
    let field = (index : Int32, name : String) => {
      hex_field(archive, at + 6 + index * 8, at, name)
    }
    let ino = field(0, "ino")
    let mode = field(1, "mode")
    let uid = field(2, "uid")
    let gid = field(3, "gid")
    let nlink = field(4, "nlink")
    let mtime = field(5, "mtime")
    let size = field(6, "size")
    let dev_major = field(7, "dev_major")
    let dev_minor = field(8, "dev_minor")
    let rdev_major = field(9, "rdev_major")
    let rdev_minor = field(10, "rdev_minor")
    let name_size = field(11, "namesize")
    let remaining = (archive.length() - pos - HEADER_SIZE).to_int64()
    if name_size < 1L || name_size > remaining {
      raise CpioError::Corrupt(
        offset=pos,
        message="name size \{name_size} does not fit the archive",
      )
    }
    let name_start = pos + HEADER_SIZE
    let name_end = name_start + name_size.to_int() - 1
    if archive[name_end] != b'\x00' {
      raise CpioError::Corrupt(
        offset=pos,
        message="file name is not NUL terminated",
      )
    }
    let data_start = (name_start + name_size.to_int() + 3) / 4 * 4
    if size > (archive.length() - data_start).to_int64() {
      raise CpioError::Corrupt(
        offset=pos,
        message="entry declares \{size} bytes but only \{archive.length() - data_start} remain",
      )
    }
    let data_end = data_start + size.to_int()
    let path = @utf8.decode_lossy(archive[name_start:name_end])
    pos = (data_end + 3) / 4 * 4
    if path == TRAILER {
      break
    }
    if entries.length() >= max_entries {
      raise CpioError::Corrupt(
        offset=at,
        message="more than \{max_entries} entries",
      )
    }
    entries.push({
      path,
      data: archive[data_start:data_end].to_owned(),
      mode: mode.to_int(),
      uid: uid.to_int(),
      gid: gid.to_int(),
      nlink: nlink.to_int(),
      mtime,
      ino: ino.to_int(),
      dev_major: dev_major.to_int(),
      dev_minor: dev_minor.to_int(),
      rdev_major: rdev_major.to_int(),
      rdev_minor: rdev_minor.to_int(),
    })
  }
  entries
}
