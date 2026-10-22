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
/// Data that compresses a little: random words from a small vocabulary.
fn Rng::text(self : Rng, n : Int32) -> Bytes {
  let words = [
    "alpha ", "beta ", "gamma\n", "delta ", "usr/bin/", "package ", "0123456789",
  ]
  let out = StringBuilder()
  let mut length = 0
  while length < n {
    let word = words[self.below(words.length())]
    out.write_string(word)
    length += word.length()
  }
  @utf8.encode(out.to_string()[0:n])
}

///|
fn Rng::noise(self : Rng, n : Int32) -> Bytes {
  Bytes::makei(n, _ => self.below(256).to_byte())
}

///|
test "property: text of many sizes round-trips through every compression" {
  let rng = { state: 3L, }
  for size in [0, 1, 2, 10, 100, 1000, 4096, 20000] {
    let data = rng.text(size)
    for c in [@compress.Compression::None, Gzip, Xz, Zstd] {
      assert_eq(
        @compress.decompress(@compress.compress(data[:], c)[:], c),
        data,
      )
    }
  }
}

///|
test "property: noise round-trips through every compression" {
  let rng = { state: 4L, }
  for size in [1, 7, 300, 5000] {
    let data = rng.noise(size)
    for c in [@compress.Compression::Gzip, Xz, Zstd] {
      assert_eq(
        @compress.decompress(@compress.compress(data[:], c)[:], c),
        data,
      )
    }
  }
}

///|
test "repetitive data shrinks with gzip and xz" {
  let data = Bytes::make(50000, b'a')
  assert_true(@compress.compress(data[:], Gzip).length() < 500)
  assert_true(@compress.compress(data[:], Xz).length() < 500)
}

///|
test "detect recognises each format by its first bytes" {
  let data = b"hello hello hello hello"
  for c in [@compress.Compression::Gzip, Xz, Zstd] {
    assert_eq(@compress.detect(@compress.compress(data[:], c)[:]), c)
  }
  assert_eq(@compress.detect(b"plain text"[:]), @compress.Compression::None)
  assert_eq(@compress.detect(b""[:]), @compress.Compression::None)
}

///|
test "names and extensions of the compressions" {
  let table = [
    (@compress.Compression::None, "none", ""),
    (Gzip, "gzip", ".gz"),
    (Xz, "xz", ".xz"),
    (Zstd, "zstd", ".zst"),
  ]
  for row in table {
    assert_eq(row.0.name(), row.1)
    assert_eq(row.0.extension(), row.2)
    assert_eq(@compress.Compression::parse(row.1), Some(row.0))
  }
  assert_eq(
    @compress.Compression::parse("gz"),
    Some(@compress.Compression::Gzip),
  )
  assert_eq(
    @compress.Compression::parse("zst"),
    Some(@compress.Compression::Zstd),
  )
  assert_eq(@compress.Compression::parse("bzip2"), None)
  assert_eq(
    @compress.Compression::from_extension(".xz"),
    Some(@compress.Compression::Xz),
  )
  assert_eq(@compress.Compression::from_extension(".bz2"), None)
}

///|
test "lzma can be read but not written" {
  assert_true(
    try @compress.compress(b"x"[:], Lzma) catch {
      @compress.Unsupported(_) => true
      _ => false
    } noraise {
      _ => false
    },
  )
}

///|
test "the unpacked size limit stops every format" {
  let data = Bytes::make(100000, b'a')
  for c in [@compress.Compression::None, Gzip, Xz, Zstd] {
    let packed = @compress.compress(data[:], c)
    assert_eq(@compress.decompress(packed[:], c, max_size=100000), data)
    assert_true(
      try @compress.decompress(packed[:], c, max_size=99999) catch {
        @compress.TooLarge(_) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "gzip_members splits concatenated streams and keeps their bytes" {
  let a = @compress.compress(b"first"[:], Gzip)
  let b = @compress.compress(b"second stream"[:], Gzip)
  let c = @compress.compress(b""[:], Gzip)
  let joined = Bytes::from_array([..a, ..b, ..c])
  let members = @compress.gzip_members(joined[:])
  assert_eq(members.length(), 3)
  assert_eq(members[0].0, a)
  assert_eq(members[1].1, b"second stream")
  assert_eq(members[2].1, b"")
}

///|
test "property: cutting a stream never crashes and never succeeds early" {
  let rng = { state: 8L, }
  let data = rng.text(3000)
  for c in [@compress.Compression::Gzip, Xz, Zstd] {
    let packed = @compress.compress(data[:], c)
    let mut cut = 1
    while cut < packed.length() {
      let result = try Some(@compress.decompress(packed[0:cut], c)) catch {
        _ => None
      } noraise {
        out => out
      }
      match result {
        Some(out) => assert_true(out != data)
        None => ()
      }
      cut += 13
    }
  }
}

///|
test "property: flipped bits are an error or different data, never a crash" {
  let rng = { state: 9L, }
  let data = rng.text(2000)
  for c in [@compress.Compression::Gzip, Xz, Zstd] {
    let packed = @compress.compress(data[:], c).to_array()
    for i in 0..<packed.length() {
      if i % 11 == 0 {
        let copy = packed.copy()
        copy[i] = copy[i] ^ 0x10
        ignore(
          try @compress.decompress(Bytes::from_array(copy)[:], c) catch {
            _ => b""
          } noraise {
            out => out
          },
        )
      }
    }
  }
}

///|
test "decompressing with the wrong format is an error" {
  let gz = @compress.compress(b"data data data"[:], Gzip)
  for wrong in [@compress.Compression::Xz, Zstd] {
    assert_true(
      try @compress.decompress(gz[:], wrong) catch {
        _ => true
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "compression is deterministic" {
  let rng = { state: 10L, }
  let data = rng.text(5000)
  for c in [@compress.Compression::Gzip, Xz, Zstd] {
    assert_eq(@compress.compress(data[:], c), @compress.compress(data[:], c))
  }
}
