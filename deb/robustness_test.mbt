///|
fn sample_deb(compression~ : @compress.Compression = Gzip) -> Bytes raise {
  @deb.build(
    @spec.PackageSpec::new(
      name="fuzz",
      version="1.0",
      arch=@spec.Arch::All,
      maintainer="Jane <jane@example.org>",
      description="Fuzz\nBody",
      entries=[
        @spec.Entry::file("/usr/bin/f", b"#!/bin/sh\n", mode=0o755),
        @spec.Entry::file("/etc/f.conf", b"x", config=true),
        @spec.Entry::symlink("/usr/bin/g", "f"),
      ],
      scripts={
        pre_install: None,
        post_install: Some("#!/bin/sh\n"),
        pre_remove: None,
        post_remove: None,
      },
    ),
    compression~,
  )
}

///|
fn survives(deb : BytesView) -> Unit {
  try {
    let pkg = @deb.read(deb)
    ignore(pkg.verify())
    ignore(pkg.to_json().stringify())
  } catch {
    _ => ()
  }
}

///|
let all_compressions : Array[@compress.Compression] = [Gzip, Xz, Zstd, None]

///|
test "every truncation of a deb is handled, for every compression" {
  for compression in all_compressions {
    let deb = sample_deb(compression~)
    for cut in 0..<deb.length() {
      survives(deb[0:cut])
    }
  }
}

///|
test "every flipped byte of a deb is handled, for every compression" {
  for compression in all_compressions {
    let deb = sample_deb(compression~)
    let copy : FixedArray[Byte] = FixedArray::makei(deb.length(), i => deb[i])
    for i in 0..<deb.length() {
      let saved = copy[i]
      copy[i] = (saved.to_int() ^ 0xff).to_byte()
      survives(Bytes::from_array(copy[:]))
      copy[i] = 0
      survives(Bytes::from_array(copy[:]))
      copy[i] = saved
    }
  }
}

///|
test "xz and zstd members that unpack to a huge size are stopped" {
  let zeros = Bytes::make(4 * 1024 * 1024, b'\x00')
  let kinds : Array[(@compress.Compression, String)] = [
    (Xz, ".xz"),
    (Zstd, ".zst"),
  ]
  for pair in kinds {
    let bomb = @compress.compress(zeros, pair.0)
    let deb = @ar.build([
      @ar.Member::new("debian-binary", b"2.0\n"),
      @ar.Member::new("control.tar" + pair.1, bomb),
      @ar.Member::new("data.tar" + pair.1, bomb),
    ])
    try @deb.read(deb, max_unpacked=1024 * 1024) catch {
      err =>
        assert_eq(
          "\{err}",
          "corrupt deb: control.tar\{pair.1} unpacks to more than 1048576 bytes",
        )
    } noraise {
      _ => fail("expected the limit to be hit")
    }
  }
}

///|
test "a package that unpacks to a huge size is stopped" {
  let bomb = @compress.compress(Bytes::make(4 * 1024 * 1024, b'\x00'), Gzip)
  let deb = @ar.build([
    @ar.Member::new("debian-binary", b"2.0\n"),
    @ar.Member::new("control.tar.gz", bomb),
    @ar.Member::new("data.tar.gz", bomb),
  ])
  try @deb.read(deb, max_unpacked=1024 * 1024) catch {
    err =>
      inspect(
        "\{err}",
        content="corrupt deb: control.tar.gz unpacks to more than 1048576 bytes",
      )
  } noraise {
    _ => fail("expected the limit to be hit")
  }
}
