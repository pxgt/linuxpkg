///|
/// The 8 bytes every ar archive starts with.
const MAGIC : Bytes = b"!<arch>\n"

///|
/// Length of a member header.
const HEADER_SIZE : Int32 = 60

///|
/// Longest member name that fits the 16-byte name field.
const MAX_NAME_LENGTH : Int32 = 16

///|
/// Largest member size representable in the 10 decimal digits of the header.
const MAX_MEMBER_SIZE : Int64 = 9999999999L

///|
fn put_text(
  header : FixedArray[Byte],
  offset : Int32,
  width : Int32,
  text : BytesView,
) -> Unit {
  for i in 0..<width {
    header[offset + i] = if i < text.length() { text[i] } else { b' ' }
  }
}

///|
/// Write a number left aligned and space padded, in decimal or octal.
fn put_number(
  header : FixedArray[Byte],
  offset : Int32,
  width : Int32,
  value : Int64,
  radix : Int32,
  field : String,
) -> Unit raise ArError {
  if value < 0L {
    raise ArError::Invalid(field~, message="must not be negative")
  }
  let digits = value.to_string(radix~)
  let text = @utf8.encode(digits)
  if text.length() > width {
    raise ArError::Invalid(
      field~,
      message="\{digits} does not fit in \{width} characters",
    )
  }
  put_text(header, offset, width, text[:])
}

///|
fn encode_header(item : Member) -> Bytes raise ArError {
  let name = @utf8.encode(item.name)
  if name.length() == 0 {
    raise ArError::Invalid(field="name", message="must not be empty")
  }
  if name.length() > MAX_NAME_LENGTH {
    raise ArError::Invalid(
      field="name",
      message="\"\{item.name}\" is \{name.length()} bytes long, at most \{MAX_NAME_LENGTH} fit",
    )
  }
  for b in name {
    if b == b'/' || b < b' ' || b == b'\x7f' {
      raise ArError::Invalid(
        field="name",
        message="\"\{item.name}\" must not contain '/' or control characters",
      )
    }
  }
  if name[name.length() - 1] == b' ' {
    raise ArError::Invalid(
      field="name",
      message="\"\{item.name}\" must not end with a space",
    )
  }
  let size = item.data.length().to_int64()
  if size > MAX_MEMBER_SIZE {
    raise ArError::Invalid(
      field="size",
      message="member is larger than \{MAX_MEMBER_SIZE} bytes",
    )
  }
  let header : FixedArray[Byte] = FixedArray::make(HEADER_SIZE, b' ')
  put_text(header, 0, MAX_NAME_LENGTH, name[:])
  put_number(header, 16, 12, item.mtime, 10, "mtime")
  put_number(header, 28, 6, item.uid.to_int64(), 10, "uid")
  put_number(header, 34, 6, item.gid.to_int64(), 10, "gid")
  put_number(header, 40, 8, item.mode.to_int64(), 8, "mode")
  put_number(header, 48, 10, size, 10, "size")
  header[58] = b'`'
  header[59] = b'\n'
  Bytes::from_array(header[:])
}

///|
/// Serialize members into an ar archive in the Debian flavour: names are
/// space padded and carry no trailing `/`, and member data is padded with a
/// newline to an even length.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @ar.build([@ar.Member::new("debian-binary", b"2.0\n")])
///   // magic + 60 byte header + 4 bytes of data
///   assert_eq(archive.length(), 8 + 60 + 4)
/// }
/// ```
pub fn build(members : Array[Member]) -> Bytes raise ArError {
  let out = Buffer(size_hint=4096)
  out.write_bytes(MAGIC)
  for item in members {
    out.write_bytes(encode_header(item))
    out.write_bytes(item.data)
    if item.data.length() % 2 == 1 {
      out.write_byte(b'\n')
    }
  }
  out.to_bytes()
}
