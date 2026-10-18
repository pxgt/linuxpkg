///|
test "GNU long name layout" {
  let path = "./" + "p".repeat(150) + "/" + "q".repeat(150)
  let archive = @tar.build(
    [@tar.Entry::file(path, b"data", mtime=1700000000L)],
    long_names=Gnu,
  )
  // The pseudo entry: name, type 'L' and the NUL terminated path as data.
  assert_eq(text_at(archive, 0, 100), "././@LongLink")
  assert_eq(archive[156], b'L')
  assert_eq(text_at(archive, 124, 12), "00000000460") // 304 bytes = path + NUL
  assert_eq(text_at(archive, 512, 512), path)
  assert_eq(archive[512 + path.length()], b'\x00')
  // 304 bytes of data take one block, so the real header follows at 1024.
  assert_eq(archive[1024 + 156], b'0')
  assert_eq(text_at(archive, 1024, 100), path[0:100].to_owned())
  assert_eq(text_at(archive, 1024 + 136, 12), "14524770400")
  assert_eq(archive.length(), 4 * 512 + 1024)
}

///|
test "GNU long link targets use a K entry" {
  let target = "../" + "t".repeat(200)
  let archive = @tar.build(
    [@tar.Entry::symlink("./usr/link", target)],
    long_names=Gnu,
  )
  assert_eq(text_at(archive, 0, 100), "././@LongLink")
  assert_eq(archive[156], b'K')
  assert_eq(text_at(archive, 512, 512), target)
  assert_eq(archive[1024 + 156], b'2')
  assert_eq(text_at(archive, 1024, 100), "./usr/link")
  assert_eq(text_at(archive, 1024 + 157, 100), target[0:100].to_owned())
}

///|
test "a long name and a long link produce K then L" {
  let path = "./" + "p".repeat(150) + "/" + "q".repeat(150)
  let target = "../" + "t".repeat(200)
  let archive = @tar.build([@tar.Entry::symlink(path, target)], long_names=Gnu)
  assert_eq(archive[156], b'K')
  assert_eq(archive[1024 + 156], b'L')
  assert_eq(archive[2048 + 156], b'2')
  assert_eq(archive.length(), 3 * 1024 + 1024 - 512)
}

///|
test "names that fit the prefix need no extension in either mode" {
  let dir = "d".repeat(60) + "/" + "e".repeat(60)
  let entries = [@tar.Entry::file("./\{dir}/file.txt", b"x")]
  assert_eq(
    @tar.build(entries, long_names=Gnu),
    @tar.build(entries, long_names=Pax),
  )
}
