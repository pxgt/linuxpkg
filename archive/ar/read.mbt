///|
/// Read a number stored as space padded ASCII digits. An all-blank field
/// reads as 0, which some tools produce for unused ids.
fn read_number(
  data : BytesView,
  offset : Int32,
  width : Int32,
  radix : Int32,
  field : String,
  member_offset : Int32,
) -> Int64 raise ArError {
  let mut end = offset + width
  while end > offset && data[end - 1] == b' ' {
    end -= 1
  }
  let mut value = 0L
  for i in offset..<end {
    let digit = data[i].to_int() - 48
    if digit < 0 || digit >= radix {
      raise ArError::Corrupt(
        offset=member_offset,
        message="\{field} field contains a non-digit byte",
      )
    }
    value = value * radix.to_int64() + digit.to_int64()
    if value > 0x7fffffffffffL {
      raise ArError::Corrupt(
        offset=member_offset,
        message="\{field} field is too large",
      )
    }
  }
  value
}

///|
fn read_name_field(data : BytesView, offset : Int32) -> Bytes {
  let mut end = offset + MAX_NAME_LENGTH
  while end > offset && data[end - 1] == b' ' {
    end -= 1
  }
  data[offset:end].to_owned()
}

///|
/// Look up the name starting at `index` in a GNU long name table; names end
/// with `/` and a newline.
fn gnu_table_name(
  table : Bytes,
  index : Int32,
  member_offset : Int32,
) -> Bytes raise ArError {
  if index < 0 || index >= table.length() {
    raise ArError::Corrupt(
      offset=member_offset,
      message="long name reference \{index} is outside the name table",
    )
  }
  let mut end = index
  while end < table.length() && table[end] != b'/' && table[end] != b'\n' {
    end += 1
  }
  table[index:end].to_owned()
}

///|
/// Parse an ar archive.
///
/// Debian style names, GNU names (`name/`, long names through the `//` table)
/// and BSD long names (`#1/<length>`) are understood; GNU symbol tables are
/// skipped. `max_members` bounds the work done on hostile input.
///
/// # Example
/// ```mbt check
/// test {
///   let archive = @ar.build([@ar.Member::new("a.txt", b"hello")])
///   let members = @ar.parse(archive)
///   assert_eq(members.length(), 1)
///   assert_eq(members[0].name, "a.txt")
///   assert_eq(members[0].data, b"hello")
/// }
/// ```
pub fn parse(
  archive : BytesView,
  max_members~ : Int32 = 65536,
) -> Array[Member] raise ArError {
  if archive.length() < MAGIC.length() ||
    archive[0:MAGIC.length()].to_owned() != MAGIC {
    raise ArError::Corrupt(offset=0, message="missing \"!<arch>\" signature")
  }
  let members : Array[Member] = []
  let mut gnu_table : Bytes = b""
  let mut pos = MAGIC.length()
  while pos < archive.length() {
    if archive.length() - pos < HEADER_SIZE {
      raise ArError::Corrupt(
        offset=pos,
        message="truncated member header (\{archive.length() - pos} bytes left)",
      )
    }
    if archive[pos + 58] != b'`' || archive[pos + 59] != b'\n' {
      raise ArError::Corrupt(
        offset=pos,
        message="member header does not end with \"`\\n\"",
      )
    }
    let mtime = read_number(archive, pos + 16, 12, 10, "mtime", pos)
    let uid = read_number(archive, pos + 28, 6, 10, "uid", pos)
    let gid = read_number(archive, pos + 34, 6, 10, "gid", pos)
    let mode = read_number(archive, pos + 40, 8, 8, "mode", pos)
    let size = read_number(archive, pos + 48, 10, 10, "size", pos)
    let data_start = pos + HEADER_SIZE
    if size > (archive.length() - data_start).to_int64() {
      raise ArError::Corrupt(
        offset=pos,
        message="member declares \{size} bytes but only \{archive.length() - data_start} remain",
      )
    }
    let mut data_begin = data_start
    let data_end = data_start + size.to_int()
    let mut name = read_name_field(archive, pos)
    if name.length() > 3 &&
      name[0] == b'#' &&
      name[1] == b'1' &&
      name[2] == b'/' {
      // BSD: the real name is stored in front of the data.
      let mut name_len = 0
      for i in 3..<name.length() {
        let digit = name[i].to_int() - 48
        if digit < 0 || digit > 9 || name_len > 1000000 {
          raise ArError::Corrupt(offset=pos, message="bad BSD long name length")
        }
        name_len = name_len * 10 + digit
      }
      if name_len > size.to_int() {
        raise ArError::Corrupt(
          offset=pos,
          message="BSD long name is longer than its member",
        )
      }
      name = archive[data_begin:data_begin + name_len].to_owned()
      // The name is NUL padded.
      let mut end = name.length()
      while end > 0 && name[end - 1] == b'\x00' {
        end -= 1
      }
      name = name[0:end].to_owned()
      data_begin += name_len
    } else if name == b"//" {
      gnu_table = archive[data_begin:data_end].to_owned()
      name = b""
    } else if name == b"/" || name == b"/SYM64/" {
      name = b""
    } else if name.length() > 1 && name[0] == b'/' {
      let mut index = 0
      for i in 1..<name.length() {
        let digit = name[i].to_int() - 48
        if digit < 0 || digit > 9 || index > 100000000 {
          raise ArError::Corrupt(
            offset=pos,
            message="bad GNU long name reference",
          )
        }
        index = index * 10 + digit
      }
      name = gnu_table_name(gnu_table, index, pos)
    } else if name.length() > 1 && name[name.length() - 1] == b'/' {
      name = name[0:name.length() - 1].to_owned()
    }
    if name.length() > 0 {
      if members.length() >= max_members {
        raise ArError::Corrupt(
          offset=pos,
          message="more than \{max_members} members",
        )
      }
      members.push({
        name: @utf8.decode_lossy(name),
        data: archive[data_begin:data_end].to_owned(),
        mtime,
        uid: uid.to_int(),
        gid: gid.to_int(),
        mode: mode.to_int(),
      })
    }
    // Data is padded to an even length.
    pos = data_end + size.to_int() % 2
    if pos > archive.length() {
      // A missing final padding byte is common and harmless.
      pos = archive.length()
    }
  }
  members
}
