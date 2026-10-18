///|
fn sample_archive() -> Bytes raise {
  @tar.build(
    [
      @tar.Entry::dir("./usr/"),
      @tar.Entry::file("./usr/a", b"data", mtime=5L),
      @tar.Entry::symlink("./usr/l", "../" + "t".repeat(130)),
      @tar.Entry::file("./" + "p".repeat(300), b"long"),
    ],
    long_names=Gnu,
  )
}

///|
fn survives(archive : BytesView) -> Unit {
  try @tar.parse(archive) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
test "every truncation of a valid archive is handled" {
  let archive = sample_archive()
  for cut in 0..<archive.length() {
    survives(archive[0:cut])
  }
}

///|
test "every flipped byte of a valid archive is handled" {
  let archive = sample_archive()
  let copy : FixedArray[Byte] = FixedArray::makei(archive.length(), i => {
    archive[i]
  })
  for i in 0..<archive.length() {
    let saved = copy[i]
    copy[i] = (saved.to_int() ^ 0xff).to_byte()
    survives(Bytes::from_array(copy[:]))
    copy[i] = saved
  }
}

///|
test "PAX archives are handled too" {
  let archive = @tar.build([
    @tar.Entry::file("./" + "p".repeat(300), b"long"),
    @tar.Entry::symlink("./l", "t".repeat(200)),
  ])
  for cut in 0..<archive.length() {
    survives(archive[0:cut])
  }
  let copy : FixedArray[Byte] = FixedArray::makei(archive.length(), i => {
    archive[i]
  })
  for i in 0..<1536 {
    let saved = copy[i]
    copy[i] = (saved.to_int() ^ 0x55).to_byte()
    survives(Bytes::from_array(copy[:]))
    copy[i] = saved
  }
}

///|
test "huge size claims are rejected, not allocated" {
  let archive = @tar.build([@tar.Entry::file("./f", b"abc")])
  let copy : FixedArray[Byte] = FixedArray::makei(archive.length(), i => {
    archive[i]
  })
  // size field: 11 octal sevens = 8 GiB - 1
  for i in 124..<135 {
    copy[i] = b'7'
  }
  // recompute the checksum
  for i in 148..<156 {
    copy[i] = b' '
  }
  let mut sum = 0
  for i in 0..<512 {
    sum += copy[i].to_int()
  }
  let digits = @utf8.encode(sum.to_string(radix=8))
  for i in 0..<6 {
    let pad = 6 - digits.length()
    copy[148 + i] = if i < pad { b'0' } else { digits[i - pad] }
  }
  copy[154] = 0
  copy[155] = b' '
  try @tar.parse(Bytes::from_array(copy[:])) catch {
    err => assert_true("\{err}".contains("entry declares 8589934591 bytes"))
  } noraise {
    _ => fail("expected an error")
  }
}
