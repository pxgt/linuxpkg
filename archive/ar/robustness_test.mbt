///|
fn sample_archive() -> Bytes raise {
  @ar.build([
    @ar.Member::new("debian-binary", b"2.0\n"),
    @ar.Member::new("control.tar.gz", Bytes::make(33, b'c')),
    @ar.Member::new("data.tar.gz", Bytes::make(100, b'd')),
  ])
}

///|
fn survives(archive : BytesView) -> Unit {
  try @ar.parse(archive) catch {
    _ => ()
  } noraise {
    _ => ()
  }
}

///|
test "every truncation and every flipped byte is handled" {
  let archive = sample_archive()
  for cut in 0..<archive.length() {
    survives(archive[0:cut])
  }
  let copy : FixedArray[Byte] = FixedArray::makei(archive.length(), i => {
    archive[i]
  })
  for i in 0..<archive.length() {
    let saved = copy[i]
    copy[i] = (saved.to_int() ^ 0xff).to_byte()
    survives(Bytes::from_array(copy[:]))
    copy[i] = b'9'
    survives(Bytes::from_array(copy[:]))
    copy[i] = saved
  }
}

///|
test "a maximal size claim is rejected" {
  let header = "big             0           0     0     100644  9999999999`\n"
  let archive = @utf8.encode("!<arch>\n" + header + "tiny")
  try @ar.parse(archive) catch {
    err => assert_true("\{err}".contains("member declares 9999999999 bytes"))
  } noraise {
    _ => fail("expected an error")
  }
}
