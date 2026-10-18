///|
/// Hand computed bytes of a header with three tags and a region.
///
///   index: region(63, BIN, offset 10, count 16)
///          1000 STRING "ab"      at 0  (3 bytes: "ab\0")
///          1028 INT32  [5]       at 4  (padded to 4 byte alignment)
///          1030 INT16  [0x81a4]  at 8
///   data : 3 + 1 pad + 4 + 2 = 10 bytes, then the 16 byte trailer = 26
let expected_bytes : Bytes = b"\x8e\xad\xe8\x01\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x1a\x00\x00\x00\x3f\x00\x00\x00\x07\x00\x00\x00\x0a\x00\x00\x00\x10\x00\x00\x03\xe8\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x04\x04\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x01\x00\x00\x04\x06\x00\x00\x00\x03\x00\x00\x00\x08\x00\x00\x00\x01ab\x00\x00\x00\x00\x00\x05\x81\xa4\x00\x00\x00\x3f\x00\x00\x00\x07\xff\xff\xff\xc0\x00\x00\x00\x10"

///|
fn sample_header() -> @rpm.Header {
  {
    region: Some(63),
    tags: [
      { id: 1030, value: Int16([0x81a4]), },
      { id: 1000, value: Str("ab"), },
      { id: 1028, value: Int32([5]), },
    ],
  }
}

///|
test "the encoded bytes match the hand computed layout" {
  assert_eq(sample_header().encode(), expected_bytes)
}

///|
test "decode is the inverse of encode" {
  let (header, end) = @rpm.Header::decode(expected_bytes, 0)
  assert_eq(end, expected_bytes.length())
  assert_eq(header.region, Some(63))
  assert_eq(header.tags, [
    { id: 1000, value: Str("ab"), },
    { id: 1028, value: Int32([5]), },
    { id: 1030, value: Int16([0x81a4]), },
  ])
  assert_eq(header.encode(), expected_bytes)
}

///|
test "all value types survive a round trip" {
  let header : @rpm.Header = {
    region: Some(62),
    tags: [
      { id: 1, value: Int8([1, 255]), },
      { id: 2, value: Int16([1, 65535]), },
      { id: 3, value: Int32([-1, 2147483647, 0]), },
      { id: 4, value: Int64([-5L, 0x123456789abcL]), },
      { id: 5, value: Str("héllo"), },
      { id: 6, value: Bin(b"\x00\x01\x02"), },
      { id: 7, value: StrArray(["a", "", "ccc"]), },
      { id: 8, value: I18n(["C"]), },
      { id: 9, value: StrArray([]), },
      { id: 10, value: Int32([]), },
    ],
  }
  let bytes = header.encode()
  let (decoded, end) = @rpm.Header::decode(bytes, 0)
  assert_eq(end, bytes.length())
  assert_eq(decoded.region, Some(62))
  // Empty int8 etc. become empty again; compare tag by tag.
  assert_eq(decoded.tags.length(), 10)
  for i in 0..<10 {
    let want = header.tags[i]
    let got = decoded.tags[i]
    assert_eq(got.id, want.id)
    if want.id == 1 {
      assert_eq(got.value, @rpm.Value::Int8([1, 255]))
    } else {
      assert_eq(got.value, want.value)
    }
  }
}

///|
test "headers without a region" {
  let header : @rpm.Header = {
    region: None,
    tags: [{ id: 100, value: Str("C"), }, { id: 50, value: Int32([7]), }],
  }
  let bytes = header.encode()
  assert_eq(bytes.length(), 16 + 32 + 4 + 2)
  let (decoded, _) = @rpm.Header::decode(bytes, 0)
  assert_eq(decoded.region, None)
  assert_eq(decoded.tags.map(t => t.id), [50, 100])
}

///|
test "decoding starts at an offset and reports where the header ends" {
  let padded = Bytes::from_array([..b"xyz", ..expected_bytes, ..b"tail"])
  let (_, end) = @rpm.Header::decode(padded, 3)
  assert_eq(end, 3 + expected_bytes.length())
}

///|
test "accessors" {
  let header = sample_header()
  assert_eq(header.string(1000), Some("ab"))
  assert_eq(header.string(1028), None)
  assert_eq(header.ints(1028), [5])
  assert_eq(header.ints(1030), [0x81a4])
  assert_eq(header.strings(1000), ["ab"])
  assert_eq(header.strings(9999), [])
  assert_eq(header.get(9999), None)
}

///|
fn encode_error(header : @rpm.Header) -> String {
  try header.encode() catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "unencodable headers are rejected" {
  inspect(
    encode_error({
      region: None,
      tags: [{ id: 5, value: Str("a"), }, { id: 5, value: Str("b"), }],
    }),
    content="tag 5: appears more than once",
  )
  inspect(
    encode_error({ region: Some(63), tags: [{ id: 63, value: Str("a"), }], }),
    content="tag 63: is the region tag of this header",
  )
  inspect(
    encode_error({ region: None, tags: [{ id: 7, value: Str("a\u{0}b"), }], }),
    content="tag 7: strings must not contain NUL",
  )
  inspect(
    encode_error({ region: None, tags: [{ id: 7, value: Int16([70000]), }], }),
    content="tag 7: 70000 does not fit in 16 bits",
  )
  inspect(
    encode_error({ region: None, tags: [{ id: 7, value: Int8([300]), }], }),
    content="tag 7: 300 does not fit in 8 bits",
  )
}

///|
fn decode_error(bytes : BytesView) -> String {
  try {
    ignore(@rpm.Header::decode(bytes, 0))
    "ok"
  } catch {
    err => "\{err}"
  }
}

///|
fn patch(source : Bytes, edits : Array[(Int32, Int32)]) -> Bytes {
  let copy : FixedArray[Byte] = FixedArray::makei(source.length(), i => {
    source[i]
  })
  for edit in edits {
    copy[edit.0] = edit.1.to_byte()
  }
  Bytes::from_array(copy[:])
}

///|
test "damaged headers are reported precisely" {
  inspect(decode_error(expected_bytes), content="ok")
  inspect(
    decode_error(b"short"),
    content="corrupt rpm at offset 0: truncated header (5 bytes left)",
  )
  inspect(
    decode_error(patch(expected_bytes, [(0, 0x00)])),
    content="corrupt rpm at offset 0: bad header magic",
  )
  // 0 entries, a huge entry count, a huge data size
  inspect(
    decode_error(patch(expected_bytes, [(11, 0)])),
    content="corrupt rpm at offset 0: header claims 0 index entries",
  )
  inspect(
    decode_error(patch(expected_bytes, [(9, 0xff)])),
    content="corrupt rpm at offset 0: header claims 16711684 index entries",
  )
  inspect(
    decode_error(patch(expected_bytes, [(12, 0x7f)])),
    content="corrupt rpm at offset 0: header claims 2130706458 bytes of data",
  )
  // The data section is cut short.
  inspect(
    decode_error(expected_bytes[0:expected_bytes.length() - 4]),
    content="corrupt rpm at offset 0: header needs 106 bytes but only 102 remain",
  )
  // Unknown data type of the second entry (index starts at 16, entry 1 at 32).
  inspect(
    decode_error(patch(expected_bytes, [(32 + 7, 42)])),
    content="corrupt rpm at offset 32: tag 1000 has unknown type 42",
  )
  // An offset pointing past the data section.
  inspect(
    decode_error(patch(expected_bytes, [(32 + 11, 0x40)])),
    content="corrupt rpm at offset 32: tag 1000 points outside the data section",
  )
  // The INT32 entry claims more elements than there is data.
  inspect(
    decode_error(patch(expected_bytes, [(48 + 15, 9)])),
    content="corrupt rpm at offset 48: tag 1028 needs 36 bytes but only 22 remain",
  )
  // An unterminated string: the array entry runs into the trailer.
  inspect(
    decode_error(patch(expected_bytes, [(32 + 15, 9)])),
    content="corrupt rpm at offset 32: tag 1000: a string has count 9",
  )
  // A broken region trailer.
  inspect(
    decode_error(patch(expected_bytes, [(expected_bytes.length() - 5, 0x01)])),
    content="corrupt rpm at offset 90: region trailer does not match the region entry",
  )
}
