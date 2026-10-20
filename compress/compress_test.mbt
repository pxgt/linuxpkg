///|
fn hex_digit(c : Char) -> Int32 {
  match c {
    '0'..<='9' => c.to_int() - '0'.to_int()
    'a'..<='f' => c.to_int() - 'a'.to_int() + 10
    _ => abort("bad hex digit in fixture")
  }
}

///|
fn decode_hex(text : String) -> Bytes {
  let out : Array[Byte] = []
  let mut high = -1
  for c in text {
    if c == '\n' || c == ' ' {
      continue
    }
    if high < 0 {
      high = hex_digit(c)
    } else {
      out.push((high * 16 + hex_digit(c)).to_byte())
      high = -1
    }
  }
  Bytes::from_array(out)
}

///|
let all_kinds : Array[@compress.Compression] = [None, Gzip, Xz, Zstd]

///|
let packed_kinds : Array[@compress.Compression] = [Gzip, Xz, Zstd]

///|
let readable_kinds : Array[@compress.Compression] = [Gzip, Xz, Zstd, Lzma]

///|
let readable_kinds_with_none : Array[@compress.Compression] = [
  None,
  Gzip,
  Xz,
  Zstd,
  Lzma,
]

///|
fn plain_bytes() -> Bytes {
  @utf8.encode(plain_text())
}

///|
/// A buffer with structure (so it compresses) and some noise (so it does not
/// compress to nothing).
fn sample(size : Int32) -> Bytes {
  let data : FixedArray[Byte] = FixedArray::make(size, b'\x00')
  let mut seed = 12345
  for i in 0..<size {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    data[i] = if i / 64 % 3 == 0 {
      ((seed >> 16) & 0xFF).to_byte()
    } else {
      (65 + i % 23).to_byte()
    }
  }
  Bytes::from_array(data[:])
}

///|
fn unpack_error(
  data : Bytes,
  compression : @compress.Compression,
  max_size~ : Int32 = 1073741824,
) -> String {
  try @compress.decompress(data, compression, max_size~) catch {
    err => "\{err}"
  } noraise {
    out => "ok \{out.length()}"
  }
}

///|
test "decoders read what the real tools wrote" {
  let expected = plain_bytes()
  let cases : Array[(String, @compress.Compression)] = [
    (xz_default, Xz),
    (xz_crc32, Xz),
    (xz_sha256, Xz),
    (xz_nocheck, Xz),
    (xz_twice, Xz),
    (xz_blocks, Xz),
    (lzma_alone, Lzma),
    (zstd_3, Zstd),
    (zstd_19, Zstd),
    (zstd_nocheck, Zstd),
    (zstd_stream, Zstd),
    (gzip_9, Gzip),
  ]
  for pair in cases {
    let packed = decode_hex(pair.0)
    assert_eq(@compress.detect(packed), pair.1)
    let out = @compress.decompress(packed, pair.1)
    if pair.0 == xz_twice {
      assert_eq(out, Bytes::from_array([..expected, ..expected]))
    } else {
      assert_eq(out, expected)
    }
  }
}

///|
test "everything we write is read back, for every size" {
  for size in [0, 1, 2, 100, 4095, 4096, 65535, 65536, 200000] {
    let data = sample(size)
    for compression in all_kinds {
      let packed = @compress.compress(data, compression)
      let out = @compress.decompress(packed, compression)
      assert_eq(out, data)
      if compression != None && size > 0 {
        assert_eq(@compress.detect(packed), compression)
      }
    }
  }
}

///|
test "output is deterministic" {
  let data = sample(30000)
  for compression in packed_kinds {
    assert_eq(
      @compress.compress(data, compression),
      @compress.compress(data, compression),
    )
  }
}

///|
test "names, extensions and detection" {
  assert_eq(@compress.Compression::parse("none"), Some(None))
  assert_eq(@compress.Compression::parse("gzip"), Some(Gzip))
  assert_eq(@compress.Compression::parse("gz"), Some(Gzip))
  assert_eq(@compress.Compression::parse("xz"), Some(Xz))
  assert_eq(@compress.Compression::parse("zstd"), Some(Zstd))
  assert_eq(@compress.Compression::parse("zst"), Some(Zstd))
  assert_eq(@compress.Compression::parse("lzma"), Option::None)
  assert_eq(@compress.Compression::parse("bzip2"), Option::None)
  assert_eq(@compress.Compression::parse(""), Option::None)
  for c in readable_kinds_with_none {
    assert_eq(@compress.Compression::from_extension(c.extension()), Some(c))
  }
  assert_eq(@compress.Compression::from_extension(".bz2"), Option::None)
  inspect(
    readable_kinds_with_none.map(c => c.name()).join(","),
    content="none,gzip,xz,zstd,lzma",
  )
  // Not compressed: plain text, a tar header, too-short input.
  assert_eq(@compress.detect(b""), None)
  assert_eq(@compress.detect(b"\x1f"), None)
  assert_eq(@compress.detect(b"hello, world, this is plain text"), None)
  assert_eq(@compress.detect(b"./usr/bin/hello\x00\x00\x00\x00\x00\x00"), None)
  assert_eq(@compress.detect(b"\xfd7zXZ"), None)
}

///|
test "lzma header plausibility" {
  // props 0x5d (lc=3 lp=0 pb=2), 8 MiB dictionary, unknown size.
  let ok = b"\x5d\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff"
  assert_eq(@compress.detect(ok), Lzma)
  // 12 MiB (1.5 times a power of two) is also a valid dictionary size.
  assert_eq(
    @compress.detect(b"\x5d\x00\x00\xc0\x00\xff\xff\xff\xff\xff\xff\xff\xff"),
    Lzma,
  )
  // props >= 225, lc + lp > 4, odd dictionary sizes, absurd stored size.
  assert_eq(
    @compress.detect(b"\xe1\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff"),
    None,
  )
  assert_eq(
    @compress.detect(b"\x11\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff"),
    None,
  )
  assert_eq(
    @compress.detect(b"\x5d\x01\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff"),
    None,
  )
  assert_eq(
    @compress.detect(b"\x5d\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff"),
    None,
  )
  assert_eq(
    @compress.detect(b"\x5d\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x01"),
    None,
  )
  // Too short.
  assert_eq(@compress.detect(b"\x5d\x00\x00\x80\x00"), None)
}

///|
test "lzma cannot be written" {
  try @compress.compress(b"x", Lzma) catch {
    Unsupported(_) => ()
    err => fail("unexpected \{err}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "unpacking an uncompressed stream only checks the limit" {
  assert_eq(@compress.decompress(b"abc", None, max_size=3), b"abc")
  inspect(
    unpack_error(b"abcd", None, max_size=3),
    content="the data unpacks to more than 3 bytes",
  )
}

///|
test "a bomb is refused at the limit, for every format" {
  let zeros = Bytes::make(8 * 1024 * 1024, b'\x00')
  for compression in packed_kinds {
    let packed = @compress.compress(zeros, compression)
    assert_true(packed.length() < 40000)
    assert_eq(@compress.decompress(packed, compression), zeros)
    inspect(
      unpack_error(packed, compression, max_size=1024 * 1024),
      content="the data unpacks to more than 1048576 bytes",
    )
    // Exactly at the limit is fine.
    assert_eq(
      @compress.decompress(packed, compression, max_size=zeros.length()),
      zeros,
    )
    inspect(
      unpack_error(packed, compression, max_size=zeros.length() - 1),
      content="the data unpacks to more than 8388607 bytes",
    )
  }
}

///|
test "the unpacked size of several xz streams adds up" {
  let one = @compress.compress(Bytes::make(3000, b'a'), Xz)
  let twice = Bytes::from_array([..one, ..one])
  assert_eq(@compress.decompress(twice, Xz).length(), 6000)
  inspect(
    unpack_error(twice, Xz, max_size=5999),
    content="the data unpacks to more than 5999 bytes",
  )
  // Zero padding between streams (a multiple of four) is allowed.
  let padded = Bytes::from_array([..one, 0, 0, 0, 0, ..one])
  assert_eq(@compress.decompress(padded, Xz).length(), 6000)
}

///|
fn damaged(data : Bytes, at : Int32, mask : Int32) -> Bytes {
  let copy : FixedArray[Byte] = FixedArray::makei(data.length(), i => data[i])
  copy[at] = (copy[at].to_int() ^ mask).to_byte()
  Bytes::from_array(copy[:])
}

///|
test "truncated streams are errors, never crashes" {
  let data = plain_bytes()
  for compression in packed_kinds {
    let packed = @compress.compress(data, compression)
    let step = packed.length() / 60 + 1
    let mut at = 0
    while at < packed.length() {
      let cut = packed[0:at].to_owned()
      let result = unpack_error(cut, compression)
      assert_true(!result.has_prefix("ok"))
      at += step
    }
    // One byte short.
    let result = unpack_error(
      packed[0:packed.length() - 1].to_owned(),
      compression,
    )
    assert_true(!result.has_prefix("ok"))
  }
}

///|
test "flipped bytes never produce wrong data silently" {
  let data = plain_bytes()
  for compression in packed_kinds {
    let packed = @compress.compress(data, compression)
    let step = packed.length() / 150 + 1
    let mut at = 0
    while at < packed.length() {
      for mask in [1, 0x80, 0xFF] {
        let bad = damaged(packed, at, mask)
        try @compress.decompress(bad, compression) catch {
          _ => ()
        } noraise {
          out => assert_eq(out, data)
        }
      }
      at += step
    }
  }
}

///|
test "flips in the real tools' output are caught as well" {
  let data = plain_bytes()
  for hex in [xz_default, xz_sha256, zstd_3, gzip_9] {
    let packed = decode_hex(hex)
    let compression = @compress.detect(packed)
    let step = packed.length() / 120 + 1
    let mut at = 0
    while at < packed.length() {
      let bad = damaged(packed, at, 0x55)
      try @compress.decompress(bad, compression) catch {
        _ => ()
      } noraise {
        out => assert_eq(out, data)
      }
      at += step
    }
  }
}

///|
test "wrong stream type and garbage" {
  for compression in readable_kinds {
    assert_true(!unpack_error(b"", compression).has_prefix("ok"))
    assert_true(
      !unpack_error(b"this is not compressed at all", compression).has_prefix(
        "ok",
      ),
    )
  }
  let gz = @compress.compress(b"hello", Gzip)
  assert_true(!unpack_error(gz, Xz).has_prefix("ok"))
  assert_true(!unpack_error(gz, Zstd).has_prefix("ok"))
  let xz = @compress.compress(b"hello", Xz)
  assert_true(!unpack_error(xz, Gzip).has_prefix("ok"))
  assert_true(!unpack_error(xz, Zstd).has_prefix("ok"))
}

///|
test "error messages name the format" {
  inspect(unpack_error(b"nope", Gzip), content="gzip: truncated")
  inspect(unpack_error(b"nope", Xz), content="xz: bad stream header")
  inspect(unpack_error(b"nope", Zstd), content="zstd: the stream is damaged")
  inspect(unpack_error(b"nope", Lzma), content="lzma: input too short")
}

///|
test "lzma without a stored size needs a small input" {
  // An unknown-size header followed by little data is allowed by the size
  // rule, a large claim is not: the unpacked size cannot be measured.
  let header = b"\x5d\x00\x00\x80\x00\xff\xff\xff\xff\xff\xff\xff\xff"
  let big = Bytes::from_array([..header, ..Bytes::make(300000, b'\x00')])
  inspect(
    unpack_error(big, Lzma, max_size=1000000),
    content="lzma: a stream without a stored size is too large to unpack safely",
  )
  // A stored size above the limit is a plain TooLarge.
  let sized = b"\x5d\x00\x00\x80\x00\x00\x00\x00\x10\x00\x00\x00\x00"
  inspect(
    unpack_error(sized, Lzma, max_size=1000),
    content="the data unpacks to more than 1000 bytes",
  )
}

///|
test "hand-made zstd frames: hostile headers" {
  // A raw block holding "hello", flagged as the last block.
  let block = b"\x29\x00\x00hello"
  // Window descriptor claiming a window of terabytes.
  let huge_window = Bytes::from_array([..b"\x28\xb5\x2f\xfd\x00\xff", ..block])
  inspect(unpack_error(huge_window, Zstd), content="ok 5")
  // Declared content size (256) that the block does not deliver.
  let lying_size = Bytes::from_array(
    [..b"\x28\xb5\x2f\xfd\x60\x00\x00", ..block],
  )
  assert_true(!unpack_error(lying_size, Zstd).has_prefix("ok"))
  // A declared size above the limit is refused before any decoding.
  let claims_much = Bytes::from_array(
    [..b"\x28\xb5\x2f\xfd\xe0\xff\xff\xff\xff\xff\xff\xff\x7f", ..block],
  )
  inspect(
    unpack_error(claims_much, Zstd, max_size=1000000),
    content="the data unpacks to more than 1000000 bytes",
  )
  // Reserved bit set, unknown block type, truncated block.
  let reserved = Bytes::from_array([..b"\x28\xb5\x2f\xfd\x08\x00", ..block])
  assert_true(!unpack_error(reserved, Zstd).has_prefix("ok"))
  let bad_type = b"\x28\xb5\x2f\xfd\x00\x00\x07\x00\x00"
  assert_true(!unpack_error(bad_type, Zstd).has_prefix("ok"))
  let short = b"\x28\xb5\x2f\xfd\x00\x00\x29\x00\x00hel"
  assert_true(!unpack_error(short, Zstd).has_prefix("ok"))
}

///|
test "hand-made xz streams: hostile structure" {
  let good = @compress.compress(Bytes::make(1000, b'z'), Xz)
  // Header says the stream has a huge number of index records.
  let bad = good.to_fixedarray()
  // Flip the stream flags byte 7 (check type) to an unknown large value.
  bad[7] = b'\x0f'
  assert_true(!unpack_error(Bytes::from_array(bad[:]), Xz).has_prefix("ok"))
  // A block header size byte that reaches past the end.
  let huge_header = good.to_fixedarray()
  huge_header[12] = b'\xff'
  assert_true(
    !unpack_error(Bytes::from_array(huge_header[:]), Xz).has_prefix("ok"),
  )
  // Garbage appended to a valid stream.
  let trailing = Bytes::from_array([..good, ..b"junk"])
  assert_true(!unpack_error(trailing, Xz).has_prefix("ok"))
  // Zero padding that is not a multiple of four.
  let odd_padding = Bytes::from_array([..good, 0, 0])
  assert_true(!unpack_error(odd_padding, Xz).has_prefix("ok"))
}
