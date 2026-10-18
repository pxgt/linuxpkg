///|
/// The value of one header tag, by RPM data type.
pub(all) enum Value {
  /// `RPM_INT8_TYPE` (2) and `RPM_CHAR_TYPE` (1).
  Int8(Array[Int32])
  /// `RPM_INT16_TYPE` (3).
  Int16(Array[Int32])
  /// `RPM_INT32_TYPE` (4). Values above 2^31 read back as negative numbers.
  Int32(Array[Int32])
  /// `RPM_INT64_TYPE` (5).
  Int64(Array[Int64])
  /// `RPM_STRING_TYPE` (6), exactly one string.
  Str(String)
  /// `RPM_BIN_TYPE` (7).
  Bin(Bytes)
  /// `RPM_STRING_ARRAY_TYPE` (8).
  StrArray(Array[String])
  /// `RPM_I18NSTRING_TYPE` (9), a string array indexed by locale.
  I18n(Array[String])
} derive(Eq, Debug)

///|
/// One header entry: a numeric tag and its value.
pub(all) struct Tag {
  id : Int32
  value : Value
} derive(Eq, Debug)

///|
/// A decoded or to-be-encoded rpm header (the signature header or the main
/// header). `region` is the tag number of the immutable region (62 for the
/// signature header, 63 for the main header) when the header has one.
pub(all) struct Header {
  region : Int32?
  tags : Array[Tag]
} derive(Eq, Debug)

///|
const MAGIC : Bytes = b"\x8e\xad\xe8\x01\x00\x00\x00\x00"

///|
/// Limits taken from librpm: at most 65535 entries and 256 MiB of data.
const MAX_ENTRIES : Int32 = 65535

///|
const MAX_DATA : Int32 = 268435456

///|
fn type_code(value : Value) -> Int32 {
  match value {
    Int8(_) => 2
    Int16(_) => 3
    Int32(_) => 4
    Int64(_) => 5
    Str(_) => 6
    Bin(_) => 7
    StrArray(_) => 8
    I18n(_) => 9
  }
}

///|
fn alignment(code : Int32) -> Int32 {
  match code {
    3 => 2
    4 => 4
    5 => 8
    _ => 1
  }
}

///|
fn put_be32(out : Buffer, value : Int32) -> Unit {
  out.write_byte(((value >> 24) & 0xff).to_byte())
  out.write_byte(((value >> 16) & 0xff).to_byte())
  out.write_byte(((value >> 8) & 0xff).to_byte())
  out.write_byte((value & 0xff).to_byte())
}

///|
fn put_be16(out : Buffer, value : Int32) -> Unit {
  out.write_byte(((value >> 8) & 0xff).to_byte())
  out.write_byte((value & 0xff).to_byte())
}

///|
fn put_be64(out : Buffer, value : Int64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    out.write_byte(((value >> shift) & 0xffL).to_int().to_byte())
  }
}

///|
/// Encode the value into `data`; returns the entry count.
fn encode_value(
  data : Buffer,
  tag : Int32,
  value : Value,
) -> Int32 raise RpmError {
  let field = "tag \{tag}"
  match value {
    Int8(items) => {
      for v in items {
        if v < -128 || v > 255 {
          raise RpmError::Invalid(field~, message="\{v} does not fit in 8 bits")
        }
        data.write_byte((v & 0xff).to_byte())
      }
      items.length()
    }
    Int16(items) => {
      for v in items {
        if v < -32768 || v > 65535 {
          raise RpmError::Invalid(
            field~,
            message="\{v} does not fit in 16 bits",
          )
        }
        put_be16(data, v)
      }
      items.length()
    }
    Int32(items) => {
      for v in items {
        put_be32(data, v)
      }
      items.length()
    }
    Int64(items) => {
      for v in items {
        put_be64(data, v)
      }
      items.length()
    }
    Str(text) => {
      check_string(field, text)
      data.write_bytes(@utf8.encode(text))
      data.write_byte(b'\x00')
      1
    }
    Bin(bytes) => {
      data.write_bytes(bytes)
      bytes.length()
    }
    StrArray(items) | I18n(items) => {
      for text in items {
        check_string(field, text)
        data.write_bytes(@utf8.encode(text))
        data.write_byte(b'\x00')
      }
      items.length()
    }
  }
}

///|
fn check_string(field : String, text : String) -> Unit raise RpmError {
  for c in text {
    if c == '\u{0}' {
      raise RpmError::Invalid(field~, message="strings must not contain NUL")
    }
  }
}

///|
/// Serialize the header: magic, entry and data counts, the index (sorted by
/// tag, with the region entry first) and the data section (values aligned to
/// their type, followed by the 16-byte region trailer).
///
/// Tags must be unique. A header may not contain its own region tag.
pub fn Header::encode(self : Header) -> Bytes raise RpmError {
  let sorted = self.tags.copy()
  sorted.sort_by((a, b) => a.id - b.id)
  for i in 1..<sorted.length() {
    if sorted[i].id == sorted[i - 1].id {
      raise RpmError::Invalid(
        field="tag \{sorted[i].id}",
        message="appears more than once",
      )
    }
  }
  let region_entries = match self.region {
    Some(_) => 1
    None => 0
  }
  let total = sorted.length() + region_entries
  if total > MAX_ENTRIES {
    raise RpmError::Invalid(field="header", message="too many entries")
  }
  let data = Buffer()
  let index = Buffer()
  for tag in sorted {
    if self.region is Some(r) && r == tag.id {
      raise RpmError::Invalid(
        field="tag \{tag.id}",
        message="is the region tag of this header",
      )
    }
    let code = type_code(tag.value)
    let align = alignment(code)
    let pad = (align - data.length() % align) % align
    if pad > 0 {
      data.write_bytes(Bytes::make(pad, b'\x00'))
    }
    let offset = data.length()
    let count = encode_value(data, tag.id, tag.value)
    put_be32(index, tag.id)
    put_be32(index, code)
    put_be32(index, offset)
    put_be32(index, count)
  }
  let out = Buffer()
  out.write_bytes(MAGIC)
  put_be32(out, total)
  match self.region {
    Some(region) => {
      let data_length = data.length() + 16
      if data_length > MAX_DATA {
        raise RpmError::Invalid(field="header", message="too much data")
      }
      put_be32(out, data_length)
      // The region entry points at its trailer, the last 16 bytes of data.
      put_be32(out, region)
      put_be32(out, 7)
      put_be32(out, data.length())
      put_be32(out, 16)
      out.write_bytes(index.to_bytes())
      out.write_bytes(data.to_bytes())
      put_be32(out, region)
      put_be32(out, 7)
      put_be32(out, -(16 * total))
      put_be32(out, 16)
    }
    None => {
      if data.length() > MAX_DATA {
        raise RpmError::Invalid(field="header", message="too much data")
      }
      put_be32(out, data.length())
      out.write_bytes(index.to_bytes())
      out.write_bytes(data.to_bytes())
    }
  }
  out.to_bytes()
}

///|
fn get_be32(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 24) |
  (data[pos + 1].to_int() << 16) |
  (data[pos + 2].to_int() << 8) |
  data[pos + 3].to_int()
}

///|
fn get_be16(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}

///|
fn get_be64(data : BytesView, pos : Int32) -> Int64 {
  let mut value = 0L
  for i in 0..<8 {
    value = (value << 8) | data[pos + i].to_int().to_int64()
  }
  value
}

///|
fn c_strings(
  data : BytesView,
  start : Int32,
  count : Int32,
  at : Int32,
  tag : Int32,
) -> Array[String] raise RpmError {
  let result : Array[String] = []
  let mut pos = start
  for _ in 0..<count {
    let mut end = pos
    while end < data.length() && data[end] != b'\x00' {
      end += 1
    }
    if end >= data.length() {
      raise RpmError::Corrupt(
        offset=at,
        message="tag \{tag}: string is not terminated",
      )
    }
    result.push(@utf8.decode_lossy(data[pos:end]))
    pos = end + 1
  }
  result
}

///|
/// Size in bytes of a value of the given type and count, or -1 for strings,
/// whose size depends on the data.
fn value_size(code : Int32, count : Int32) -> Int32 {
  match code {
    1 | 2 | 7 => count
    3 => count * 2
    4 => count * 4
    5 => count * 8
    _ => -1
  }
}

///|
/// Decode the header that starts at `start` in `bytes`. Returns the header and
/// the position just after its data section.
///
/// The region entry, when present, is reported through `Header::region` and
/// left out of `tags`. Unknown tags are kept. Index entries and data are
/// validated against the header's own size claims and against the limits of
/// librpm (65535 entries, 256 MiB of data).
pub fn Header::decode(
  bytes : BytesView,
  start : Int32,
) -> (Header, Int32) raise RpmError {
  if start < 0 || bytes.length() - start < 16 {
    raise RpmError::Corrupt(
      offset=start,
      message="truncated header (\{bytes.length() - start} bytes left)",
    )
  }
  if bytes[start:start + 8].to_owned() != MAGIC {
    raise RpmError::Corrupt(offset=start, message="bad header magic")
  }
  let entries = get_be32(bytes, start + 8)
  let data_size = get_be32(bytes, start + 12)
  if entries < 1 || entries > MAX_ENTRIES {
    raise RpmError::Corrupt(
      offset=start,
      message="header claims \{entries} index entries",
    )
  }
  if data_size < 0 || data_size > MAX_DATA {
    raise RpmError::Corrupt(
      offset=start,
      message="header claims \{data_size} bytes of data",
    )
  }
  let index_start = start + 16
  let data_start = index_start + entries * 16
  let end = data_start + data_size
  if end > bytes.length() {
    raise RpmError::Corrupt(
      offset=start,
      message="header needs \{end - start} bytes but only \{bytes.length() - start} remain",
    )
  }
  let data = bytes[data_start:end]
  let tags : Array[Tag] = []
  let mut region : Int32? = None
  for i in 0..<entries {
    let at = index_start + i * 16
    let id = get_be32(bytes, at)
    let code = get_be32(bytes, at + 4)
    let offset = get_be32(bytes, at + 8)
    let count = get_be32(bytes, at + 12)
    if code < 1 || code > 9 {
      raise RpmError::Corrupt(
        offset=at,
        message="tag \{id} has unknown type \{code}",
      )
    }
    if count < 0 || count > MAX_DATA {
      raise RpmError::Corrupt(
        offset=at,
        message="tag \{id} has an unreasonable count \{count}",
      )
    }
    if offset < 0 || offset > data_size {
      raise RpmError::Corrupt(
        offset=at,
        message="tag \{id} points outside the data section",
      )
    }
    if i == 0 && code == 7 && count == 16 && (id == 61 || id == 62 || id == 63) {
      // The region entry: its trailer holds a copy of the entry with the
      // negated size of the index.
      if offset + 16 > data_size {
        raise RpmError::Corrupt(
          offset=at,
          message="region trailer is outside the data section",
        )
      }
      let trailer = data_start + offset
      if get_be32(bytes, trailer) != id ||
        get_be32(bytes, trailer + 4) != 7 ||
        get_be32(bytes, trailer + 8) != -(16 * entries) ||
        get_be32(bytes, trailer + 12) != 16 {
        raise RpmError::Corrupt(
          offset=trailer,
          message="region trailer does not match the region entry",
        )
      }
      region = Some(id)
      continue
    }
    let size = value_size(code, count)
    let value : Value = if size >= 0 {
      if size > data_size - offset {
        raise RpmError::Corrupt(
          offset=at,
          message="tag \{id} needs \{size} bytes but only \{data_size - offset} remain",
        )
      }
      match code {
        1 | 2 => {
          let items : Array[Int32] = []
          for k in 0..<count {
            items.push(data[offset + k].to_int())
          }
          Int8(items)
        }
        3 => {
          let items : Array[Int32] = []
          for k in 0..<count {
            items.push(get_be16(data, offset + k * 2))
          }
          Int16(items)
        }
        4 => {
          let items : Array[Int32] = []
          for k in 0..<count {
            items.push(get_be32(data, offset + k * 4))
          }
          Int32(items)
        }
        5 => {
          let items : Array[Int64] = []
          for k in 0..<count {
            items.push(get_be64(data, offset + k * 8))
          }
          Int64(items)
        }
        _ => Bin(data[offset:offset + count].to_owned())
      }
    } else if code == 6 {
      let strings = c_strings(data, offset, 1, at, id)
      if count != 1 {
        raise RpmError::Corrupt(
          offset=at,
          message="tag \{id}: a string has count \{count}",
        )
      }
      Str(strings[0])
    } else {
      if count > data_size - offset {
        raise RpmError::Corrupt(
          offset=at,
          message="tag \{id} claims \{count} strings in \{data_size - offset} bytes",
        )
      }
      let strings = c_strings(data, offset, count, at, id)
      if code == 8 {
        StrArray(strings)
      } else {
        I18n(strings)
      }
    }
    tags.push({ id, value, })
  }
  ({ region, tags, }, end)
}

///|
/// The value of `id`, if the header has it.
pub fn Header::get(self : Header, id : Int32) -> Value? {
  for tag in self.tags {
    if tag.id == id {
      return Some(tag.value)
    }
  }
  None
}

///|
/// The tag as a single string (`Str`, or the first element of a string array).
pub fn Header::string(self : Header, id : Int32) -> String? {
  match self.get(id) {
    Some(Str(text)) => Some(text)
    Some(StrArray(items)) | Some(I18n(items)) =>
      if items.length() > 0 {
        Some(items[0])
      } else {
        None
      }
    _ => None
  }
}

///|
/// The tag as a list of strings.
pub fn Header::strings(self : Header, id : Int32) -> Array[String] {
  match self.get(id) {
    Some(StrArray(items)) | Some(I18n(items)) => items
    Some(Str(text)) => [text]
    _ => []
  }
}

///|
/// The tag as a list of integers (any integer type, 64-bit values truncated).
pub fn Header::ints(self : Header, id : Int32) -> Array[Int32] {
  match self.get(id) {
    Some(Int8(items)) | Some(Int16(items)) | Some(Int32(items)) => items
    Some(Int64(items)) => items.map(v => v.to_int())
    _ => []
  }
}
