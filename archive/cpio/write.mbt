///|
const MAGIC : String = "070701"

///|
const HEADER_SIZE : Int32 = 110

///|
const TRAILER : String = "TRAILER!!!"

///|
fn put_hex(out : Buffer, value : Int64, field : String) -> Unit raise CpioError {
  if value < 0L || value > 0xffffffffL {
    raise CpioError::Invalid(field~, message="\{value} does not fit in 32 bits")
  }
  let digits = value.to_string(radix=16)
  out.write_bytes(@utf8.encode("0".repeat(8 - digits.length())))
  out.write_bytes(@utf8.encode(digits))
}

///|
fn pad4(out : Buffer, length : Int32) -> Unit {
  let rest = length % 4
  if rest != 0 {
    out.write_bytes(Bytes::make(4 - rest, b'\x00'))
  }
}

///|
fn write_entry(out : Buffer, entry : Entry) -> Unit raise CpioError {
  let name = @utf8.encode(entry.path)
  if name.length() == 0 {
    raise CpioError::Invalid(field="path", message="must not be empty")
  }
  for b in name {
    if b == b'\x00' {
      raise CpioError::Invalid(field="path", message="must not contain NUL")
    }
  }
  out.write_bytes(@utf8.encode(MAGIC))
  put_hex(out, entry.ino.to_int64(), "ino")
  put_hex(out, entry.mode.to_int64(), "mode")
  put_hex(out, entry.uid.to_int64(), "uid")
  put_hex(out, entry.gid.to_int64(), "gid")
  put_hex(out, entry.nlink.to_int64(), "nlink")
  put_hex(out, entry.mtime, "mtime")
  put_hex(out, entry.data.length().to_int64(), "size")
  put_hex(out, entry.dev_major.to_int64(), "dev_major")
  put_hex(out, entry.dev_minor.to_int64(), "dev_minor")
  put_hex(out, entry.rdev_major.to_int64(), "rdev_major")
  put_hex(out, entry.rdev_minor.to_int64(), "rdev_minor")
  put_hex(out, (name.length() + 1).to_int64(), "namesize")
  put_hex(out, 0L, "check")
  out.write_bytes(name)
  out.write_byte(b'\x00')
  pad4(out, HEADER_SIZE + name.length() + 1)
  out.write_bytes(entry.data)
  pad4(out, entry.data.length())
}

///|
/// Serialize entries as a `newc` archive followed by the `TRAILER!!!`
/// record. The output depends only on the entries.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @cpio.build([@cpio.Entry::file("./a", b"xyz")])
///   assert_eq(archive.length() % 4, 0)
/// }
/// ```
pub fn build(entries : Array[Entry]) -> Bytes raise CpioError {
  let out = Buffer(size_hint=4096)
  for entry in entries {
    write_entry(out, entry)
  }
  write_entry(out, Entry::file(TRAILER, b"", mode=0))
  out.to_bytes()
}
