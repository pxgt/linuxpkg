///|
test "round trip and multiple members" {
  let a = @gzip.compress(b"hello ")
  let b = @gzip.compress(b"world")
  assert_eq(
    @gunzip.decompress(Bytes::from_array([..a, ..b]), max_size=100),
    b"hello world",
  )
  assert_eq(@gunzip.decompress(@gzip.compress(b""), max_size=0), b"")
}

///|
test "output larger than one decoder chunk" {
  let data = Bytes::make(300000, b'q')
  let packed = @gzip.compress(data)
  assert_eq(@gunzip.decompress(packed, max_size=300000), data)
}

///|
test "a gzip bomb is stopped at the limit" {
  // 8 MiB of zeros compress to a few kilobytes.
  let packed = @gzip.compress(Bytes::make(8 * 1024 * 1024, b'\x00'))
  assert_true(packed.length() < 20000)
  try @gunzip.decompress(packed, max_size=1024 * 1024) catch {
    TooLarge(limit) => assert_eq(limit, 1024 * 1024)
    Corrupt(message) => fail("unexpected corruption: \{message}")
  } noraise {
    _ => fail("expected the limit to be hit")
  }
}

///|
test "damaged and truncated streams" {
  let packed = @gzip.compress(
    b"some data that is long enough to matter, some data",
  )
  for cut in 0..<packed.length() {
    try @gunzip.decompress(packed[0:cut], max_size=1000) catch {
      Corrupt(_) => ()
      TooLarge(_) => fail("limit is not the problem at \{cut}")
    } noraise {
      _ => fail("a prefix of \{cut} bytes must not decode")
    }
  }
  // Flip the CRC.
  let bad = Bytes::from_array(
    packed
    .to_array()
    .mapi((i, b) => {
      if i == packed.length() - 6 {
        (b.to_int() ^ 0xff).to_byte()
      } else {
        b
      }
    }),
  )
  try @gunzip.decompress(bad, max_size=1000) catch {
    Corrupt(_) => ()
    TooLarge(_) => fail("unexpected limit")
  } noraise {
    _ => fail("a bad CRC must be rejected")
  }
}
