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
fn Rng::bytes(self : Rng, n : Int32) -> Bytes {
  Bytes::makei(n, _ => self.below(256).to_byte())
}

///|
fn random_entries(rng : Rng, count : Int32) -> Array[@cpio.Entry] {
  let entries : Array[@cpio.Entry] = []
  for i in 0..<count {
    let path = "./usr/share/d\{i}/file\{rng.below(1000)}"
    let mtime = rng.next().to_int64()
    match rng.below(3) {
      0 => entries.push(@cpio.Entry::dir(path, mtime~, ino=i + 1))
      1 =>
        entries.push(
          @cpio.Entry::symlink(path, "target\{i}", mtime~, ino=i + 1),
        )
      _ =>
        entries.push(
          @cpio.Entry::file(
            path,
            rng.bytes(rng.below(500)),
            mode=0o100000 + rng.below(0o7777 + 1),
            mtime~,
            ino=i + 1,
          ),
        )
    }
  }
  entries
}

///|
test "property: random entries read back as written" {
  let rng = { state: 3L, }
  for _ in 0..<30 {
    let entries = random_entries(rng, 1 + rng.below(8))
    assert_eq(@cpio.parse(@cpio.build(entries)[:]), entries)
  }
}

///|
test "the archive is 4-byte aligned and ends with the trailer" {
  let rng = { state: 9L, }
  for _ in 0..<10 {
    let archive = @cpio.build(random_entries(rng, 5))
    assert_eq(archive.length() % 4, 0)
    assert_true(
      @utf8.decode_lossy(archive[archive.length() - 40:]).contains("TRAILER!!!"),
    )
    assert_eq(archive[0:6].to_owned(), b"070701")
  }
}

///|
test "file data of every size modulo 4 is padded and read back" {
  for size in [0, 1, 2, 3, 4, 5, 255, 256, 1000, 1001] {
    let data = Bytes::make(size, b'z')
    let entry = @cpio.Entry::file("./f", data)
    let archive = @cpio.build([entry])
    assert_eq(archive.length() % 4, 0)
    assert_eq(@cpio.parse(archive[:])[0].data, data)
  }
}

///|
test "building is deterministic" {
  let rng = { state: 2L, }
  let entries = random_entries(rng, 6)
  assert_eq(@cpio.build(entries), @cpio.build(entries))
}

///|
test "mtimes up to 2^32 - 1 are kept" {
  for t in [0L, 1L, 2147483647L, 4294967295L] {
    let archive = @cpio.build([@cpio.Entry::file("./f", b"x", mtime=t)])
    assert_eq(@cpio.parse(archive[:])[0].mtime, t)
  }
}

///|
test "property: a damaged or cut archive is an error or a shorter list, never a crash" {
  let rng = { state: 6L, }
  let archive = @cpio.build(random_entries(rng, 4)).to_array()
  for i in 0..<archive.length() {
    if i % 7 == 0 {
      let copy = archive.copy()
      copy[i] = copy[i] ^ 0xff
      ignore(
        try @cpio.parse(Bytes::from_array(copy)[:]) catch {
          _ => []
        } noraise {
          ok => ok
        },
      )
      ignore(
        try @cpio.parse(Bytes::from_array(archive[0:i])[:]) catch {
          _ => []
        } noraise {
          ok => ok
        },
      )
    }
  }
}
