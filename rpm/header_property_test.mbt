///|
priv struct Rng {
  mut state : Int64
}

///|
fn Rng::next(self : Rng) -> Int32 {
  self.state = self.state * 6364136223846793005L + 1442695040888963407L
  ((self.state >> 33) & 0x7fffffffL).to_int()
}

///|
fn Rng::below(self : Rng, n : Int32) -> Int32 {
  self.next() % n
}

///|
fn Rng::text(self : Rng) -> String {
  let n = self.below(12)
  let out = StringBuilder()
  for _ in 0..<n {
    out.write_char(
      "abcdefghijklmnopqrstuvwxyz /-."
      .unsafe_get(self.below(30))
      .unsafe_to_char(),
    )
  }
  out.to_string()
}

///|
fn random_value(rng : Rng) -> @rpm.Value {
  match rng.below(7) {
    0 => Int8(Array::makei(1 + rng.below(4), _ => rng.below(256)))
    1 => Int16(Array::makei(1 + rng.below(4), _ => rng.below(65536)))
    2 => Int32(Array::makei(1 + rng.below(4), _ => rng.next()))
    3 =>
      Int64(Array::makei(1 + rng.below(3), _ => rng.next().to_int64() * 1024L))
    4 => Str(rng.text())
    5 => StrArray(Array::makei(1 + rng.below(4), _ => rng.text()))
    _ => Bin(Bytes::makei(1 + rng.below(30), _ => rng.below(256).to_byte()))
  }
}

///|
fn random_header(rng : Rng, region : Int32?) -> @rpm.Header {
  let ids : Array[Int32] = []
  for _ in 0..<(1 + rng.below(12)) {
    let id = 1000 + rng.below(500)
    if !ids.contains(id) {
      ids.push(id)
    }
  }
  { region, tags: ids.map(id => { id, value: random_value(rng), }), }
}

///|
fn sorted_tags(header : @rpm.Header) -> Array[@rpm.Tag] {
  let tags = header.tags.copy()
  tags.sort_by((a, b) => a.id - b.id)
  tags
}

///|
test "property: random headers decode to what was encoded, sorted by tag" {
  let rng = { state: 5L, }
  for _ in 0..<40 {
    let header = random_header(rng, Some(63))
    let bytes = header.encode()
    let (back, end) = @rpm.Header::decode(bytes[:], 0)
    assert_eq(end, bytes.length())
    assert_eq(back.region, Some(63))
    assert_eq(back.tags, sorted_tags(header))
    assert_eq(back.encode(), bytes)
  }
}

///|
test "property: headers without a region round-trip too" {
  let rng = { state: 6L, }
  for _ in 0..<20 {
    let header = random_header(rng, None)
    let (back, _) = @rpm.Header::decode(header.encode()[:], 0)
    assert_eq(back.region, None)
    assert_eq(back.tags, sorted_tags(header))
  }
}

///|
test "the order of the tags does not change the bytes" {
  let rng = { state: 7L, }
  for _ in 0..<10 {
    let header = random_header(rng, Some(62))
    let reversed = { ..header, tags: header.tags.rev(), }
    assert_eq(header.encode(), reversed.encode())
  }
}

///|
test "a header starts with the magic and the counts include the region entry" {
  let header : @rpm.Header = {
    region: Some(62),
    tags: [{ id: 1000, value: Str("x"), }, { id: 1001, value: Str("y"), }],
  }
  let bytes = header.encode()
  assert_eq(bytes[0:8].to_owned(), b"\x8e\xad\xe8\x01\x00\x00\x00\x00")
  assert_eq(bytes[8:12].to_owned(), b"\x00\x00\x00\x03")
}

///|
test "integers are aligned in the data area" {
  let header : @rpm.Header = {
    region: None,
    tags: [
      { id: 1000, value: Str("a"), },
      { id: 1001, value: Int32([7]), },
      { id: 1002, value: Str("b"), },
      { id: 1003, value: Int16([9]), },
      { id: 1004, value: Int64([5L]), },
    ],
  }
  let (back, _) = @rpm.Header::decode(header.encode()[:], 0)
  assert_eq(back, header)
  // Entries are 16 bytes: tag, type, offset, count; read the offsets back.
  let bytes = header.encode()
  let offset = (i : Int32) => {
    let at = 16 + i * 16 + 8
    (bytes[at].to_int() << 24) |
    (bytes[at + 1].to_int() << 16) |
    (bytes[at + 2].to_int() << 8) |
    bytes[at + 3].to_int()
  }
  assert_eq(offset(1) % 4, 0)
  assert_eq(offset(3) % 2, 0)
  assert_eq(offset(4) % 8, 0)
}

///|
test "a tag may not appear twice and the region tag is reserved" {
  let twice : @rpm.Header = {
    region: None,
    tags: [{ id: 1000, value: Str("a"), }, { id: 1000, value: Str("b"), }],
  }
  let clash : @rpm.Header = {
    region: Some(63),
    tags: [{ id: 63, value: Str("a"), }],
  }
  for h in [twice, clash] {
    assert_true(
      try h.encode() catch {
        @rpm.Invalid(..) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "strings may not contain NUL and 8-bit values are range checked" {
  let nul : @rpm.Header = {
    region: None,
    tags: [{ id: 1000, value: Str("a\u{0}b"), }],
  }
  let big : @rpm.Header = {
    region: None,
    tags: [{ id: 1000, value: Int8([300]), }],
  }
  let wide : @rpm.Header = {
    region: None,
    tags: [{ id: 1000, value: Int16([70000]), }],
  }
  for h in [nul, big, wide] {
    assert_true(
      try h.encode() catch {
        @rpm.Invalid(..) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "property: every cut of a header is an error, never a crash" {
  let rng = { state: 8L, }
  let bytes = random_header(rng, Some(63)).encode()
  for cut in 0..<bytes.length() {
    assert_true(
      try @rpm.Header::decode(bytes[0:cut], 0) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "property: flipped bytes in a header are an error or another header" {
  let rng = { state: 9L, }
  let bytes = random_header(rng, Some(63)).encode().to_array()
  for i in 0..<bytes.length() {
    let copy = bytes.copy()
    copy[i] = copy[i] ^ 0x55
    let decoded = try
      Some(@rpm.Header::decode(Bytes::from_array(copy)[:], 0))
    catch {
      _ => None
    } noraise {
      ok => ok
    }
    ignore(decoded)
  }
}

///|
test "get, string, strings and ints read tags by number" {
  let header : @rpm.Header = {
    region: None,
    tags: [
      { id: 1, value: Str("one"), },
      { id: 2, value: StrArray(["a", "b"]), },
      { id: 3, value: Int32([4, 5]), },
    ],
  }
  assert_eq(header.string(1), Some("one"))
  assert_eq(header.strings(2), ["a", "b"])
  assert_eq(header.ints(3), [4, 5])
  assert_eq(header.string(9), None)
  assert_eq(header.strings(9), [])
  assert_eq(header.get(9), None)
}
