///|
fn sample_archive() -> Bytes raise {
  @cpio.build([
    @cpio.Entry::dir("./usr"),
    @cpio.Entry::file("./usr/a", b"data"),
    @cpio.Entry::symlink("./usr/l", "a"),
  ])
}

///|
fn survives(archive : BytesView) -> Unit {
  try @cpio.parse(archive) catch {
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
    copy[i] = b'f'
    survives(Bytes::from_array(copy[:]))
    copy[i] = saved
  }
}
