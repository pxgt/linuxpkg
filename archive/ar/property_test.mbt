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
fn random_members(rng : Rng, count : Int32) -> Array[@ar.Member] {
  let members : Array[@ar.Member] = []
  for i in 0..<count {
    members.push(
      @ar.Member::new(
        "member\{i}.bin",
        rng.bytes(rng.below(300)),
        mtime=rng.next().to_int64(),
        uid=rng.below(100000),
        gid=rng.below(100000),
        mode=rng.below(0o7777 + 1),
      ),
    )
  }
  members
}

///|
test "property: random members read back as written" {
  let rng = { state: 5L, }
  for _ in 0..<30 {
    let members = random_members(rng, 1 + rng.below(8))
    assert_eq(@ar.parse(@ar.build(members)[:]), members)
  }
}

///|
test "members of odd and even sizes are padded to even offsets" {
  for size in [0, 1, 2, 3, 59, 60, 61] {
    let archive = @ar.build([@ar.Member::new("x", Bytes::make(size, b'a'))])
    assert_eq(archive.length() % 2, 0)
    assert_eq(@ar.parse(archive[:])[0].data.length(), size)
  }
}

///|
test "an archive starts with the magic and each header is 60 bytes" {
  let archive = @ar.build([
    @ar.Member::new("a", b"1"),
    @ar.Member::new("b", b"22"),
  ])
  assert_eq(archive[0:8].to_owned(), b"!<arch>\n")
  assert_eq(archive.length(), 8 + 60 + 2 + 60 + 2)
}

///|
test "names up to 15 characters are accepted, longer or odd ones are refused" {
  for name in ["a", "debian-binary", "control.tar.xz", "x".repeat(15)] {
    assert_eq(
      @ar.parse(@ar.build([@ar.Member::new(name, b"")])[:])[0].name,
      name,
    )
  }
  for bad in ["", "x".repeat(17), "a/b", "a b\nc"] {
    assert_true(
      try @ar.build([@ar.Member::new(bad, b"")]) catch {
        @ar.Invalid(..) => true
        _ => false
      } noraise {
        _ => false
      },
    )
  }
}

///|
test "building is deterministic" {
  let rng = { state: 8L, }
  let members = random_members(rng, 5)
  assert_eq(@ar.build(members), @ar.build(members))
}

///|
test "property: a damaged or cut archive is an error or a shorter list, never a crash" {
  let rng = { state: 13L, }
  let archive = @ar.build(random_members(rng, 4)).to_array()
  for i in 0..<archive.length() {
    if i % 5 == 0 {
      let copy = archive.copy()
      copy[i] = copy[i] ^ 0xff
      ignore(
        try @ar.parse(Bytes::from_array(copy)[:]) catch {
          _ => []
        } noraise {
          ok => ok
        },
      )
      ignore(
        try @ar.parse(Bytes::from_array(archive[0:i])[:]) catch {
          _ => []
        } noraise {
          ok => ok
        },
      )
    }
  }
}
