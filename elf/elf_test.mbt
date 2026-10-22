///|
/// Append `value` as `size` bytes in the given byte order.
fn put(out : Array[Byte], value : Int64, size : Int32, little : Bool) -> Unit {
  for k in 0..<size {
    let shift = if little { k * 8 } else { (size - 1 - k) * 8 }
    out.push(((value >> shift) & 0xffL).to_byte())
  }
}

///|
/// A small ELF file made by hand: the header, a PT_LOAD, an optional
/// PT_INTERP and a PT_DYNAMIC with the string table at the start of the
/// file's second half. It is laid out like a real linker does, so the reader
/// has to follow program headers and virtual addresses.
fn make_elf(
  bits~ : Int32 = 64,
  little~ : Bool = true,
  machine~ : Int32 = 62,
  flags~ : Int32 = 0,
  interp~ : String? = None,
  needed~ : Array[String] = [],
  soname~ : String? = None,
) -> Bytes {
  let is64 = bits == 64
  let word = if is64 { 8 } else { 4 }
  let ehsize = if is64 { 64 } else { 52 }
  let phentsize = if is64 { 56 } else { 32 }
  let has_dynamic = needed.length() > 0 || soname is Some(_)
  let phnum = 1 +
    (if interp is Some(_) { 1 } else { 0 }) +
    (if has_dynamic { 1 } else { 0 })
  // Layout: header, program headers, interpreter, string table, dynamic.
  let interp_bytes : Array[Byte] = []
  if interp is Some(path) {
    for c in path {
      interp_bytes.push(c.to_int().to_byte())
    }
    interp_bytes.push(0)
  }
  let strtab : Array[Byte] = [0]
  let name_offsets : Array[Int64] = []
  let all_names : Array[String] = []
  for n in needed {
    all_names.push(n)
  }
  if soname is Some(n) {
    all_names.push(n)
  }
  for n in all_names {
    name_offsets.push(strtab.length().to_int64())
    for c in n {
      strtab.push(c.to_int().to_byte())
    }
    strtab.push(0)
  }
  let interp_at = ehsize + phnum * phentsize
  let strtab_at = interp_at + interp_bytes.length()
  let dynamic_at = strtab_at + strtab.length()
  let entries = needed.length() + (if soname is Some(_) { 1 } else { 0 }) + 2
  let dynamic_size = entries * word * 2
  let total = dynamic_at + (if has_dynamic { dynamic_size } else { 0 })
  // Virtual addresses are file offsets + 0x400000.
  let base = 0x400000L
  let out : Array[Byte] = []
  out.push(0x7f)
  out.push(b'E')
  out.push(b'L')
  out.push(b'F')
  out.push(if is64 { 2 } else { 1 })
  out.push(if little { 1 } else { 2 })
  out.push(1)
  for _ in 0..<9 {
    out.push(0)
  }
  put(out, 3L, 2, little)
  put(out, machine.to_int64(), 2, little)
  put(out, 1L, 4, little)
  put(out, base, word, little)
  put(out, ehsize.to_int64(), word, little)
  put(out, 0L, word, little)
  put(out, flags.to_int64(), 4, little)
  put(out, ehsize.to_int64(), 2, little)
  put(out, phentsize.to_int64(), 2, little)
  put(out, phnum.to_int64(), 2, little)
  put(out, 0L, 2, little)
  put(out, 0L, 2, little)
  put(out, 0L, 2, little)
  let program_header = (kind : Int64, offset : Int64, size : Int64) => {
    put(out, kind, 4, little)
    if is64 {
      put(out, 4L, 4, little)
      put(out, offset, 8, little)
      put(out, base + offset, 8, little)
      put(out, base + offset, 8, little)
      put(out, size, 8, little)
      put(out, size, 8, little)
      put(out, 8L, 8, little)
    } else {
      put(out, offset, 4, little)
      put(out, base + offset, 4, little)
      put(out, base + offset, 4, little)
      put(out, size, 4, little)
      put(out, size, 4, little)
      put(out, 4L, 4, little)
      put(out, 8L, 4, little)
    }
  }
  program_header(1L, 0L, total.to_int64())
  if interp is Some(_) {
    program_header(3L, interp_at.to_int64(), interp_bytes.length().to_int64())
  }
  if has_dynamic {
    program_header(2L, dynamic_at.to_int64(), dynamic_size.to_int64())
  }
  for b in interp_bytes {
    out.push(b)
  }
  for b in strtab {
    out.push(b)
  }
  if has_dynamic {
    let entry = (tag : Int64, value : Int64) => {
      put(out, tag, word, little)
      put(out, value, word, little)
    }
    for i in 0..<needed.length() {
      entry(1L, name_offsets[i])
    }
    if soname is Some(_) {
      entry(14L, name_offsets[needed.length()])
    }
    entry(5L, base + strtab_at.to_int64())
    entry(0L, 0L)
  }
  Bytes::from_array(out)
}

///|
test "every class and byte order is read" {
  for bits in [32, 64] {
    for little in [true, false] {
      let data = make_elf(
        bits~,
        little~,
        interp=Some("/lib/ld.so"),
        needed=["libc.so.6", "libm.so.6"],
        soname=Some("libdemo.so.1"),
      )
      let info = @elf.parse(data[:])
      assert_eq(info.bits, bits)
      assert_eq(info.little_endian, little)
      assert_eq(info.machine, 62)
      assert_eq(info.file_type, 3)
      assert_eq(info.interpreter, Some("/lib/ld.so"))
      assert_eq(info.needed, ["libc.so.6", "libm.so.6"])
      assert_eq(info.soname, Some("libdemo.so.1"))
      assert_eq(info.linkage, Dynamic)
    }
  }
}

///|
test "no interpreter and no libraries is a static file" {
  let info = @elf.parse(make_elf()[:])
  assert_eq(info.linkage, Static)
  assert_eq(info.interpreter, None)
  assert_eq(info.needed, [])
  assert_eq(info.soname, None)
}

///|
test "a shared library without NEEDED but with a soname is dynamic" {
  let info = @elf.parse(make_elf(soname=Some("libx.so"))[:])
  assert_eq(info.linkage, Dynamic)
  assert_eq(info.soname, Some("libx.so"))
}

///|
test "machine numbers map to package architectures" {
  let cases : Array[(Int32, Int32, Bool, Int32, String?)] = [
    (62, 64, true, 0, Some("amd64")),
    (183, 64, true, 0, Some("arm64")),
    (3, 32, true, 0, Some("i386")),
    (243, 64, true, 0, Some("riscv64")),
    (258, 64, true, 0, Some("loong64")),
    (22, 64, false, 0, Some("s390x")),
    (21, 64, true, 0, Some("ppc64le")),
    (8, 64, true, 0, Some("mips64le")),
    (40, 32, true, 0x5000400, Some("armhf")),
    (40, 32, true, 0x5000200, Some("armel")),
    (40, 32, true, 0, Some("armel")),
    // Not a package architecture: big endian ppc64, x32, 32-bit RISC-V, ...
    (21, 64, false, 0, None),
    (62, 32, true, 0, None),
    (243, 32, true, 0, None),
    (22, 64, true, 0, None),
    (8, 32, false, 0, None),
    (999, 64, true, 0, None),
  ]
  for c in cases {
    let (machine, bits, little, flags, want) = c
    let info = @elf.parse(make_elf(machine~, bits~, little~, flags~)[:])
    assert_eq(info.arch(), want)
  }
}

///|
test "is_elf only needs the magic number" {
  assert_true(@elf.is_elf(b"\x7fELF"))
  assert_false(@elf.is_elf(b"\x7fEL"))
  assert_false(@elf.is_elf(b"MZ\x90\x00"))
  assert_false(@elf.is_elf(b""))
}

///|
test "what is not an ELF file is NotElf, a cut-off header is Truncated" {
  let not_elf : Array[Bytes] = [b"", b"#!/bin/sh\n", b"\x7fEL"]
  for data in not_elf {
    try @elf.parse(data[:]) catch {
      NotElf => ()
      e => fail("expected NotElf, got \{e}")
    } noraise {
      _ => fail("expected an error")
    }
  }
  try @elf.parse(b"\x7fELF\x02\x01\x01"[:]) catch {
    Truncated(_) => ()
    e => fail("expected Truncated, got \{e}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "unknown class and byte order are refused" {
  let good = make_elf().to_array()
  for field in [(4, 0), (4, 3), (5, 0), (5, 9)] {
    let copy = good.copy()
    copy[field.0] = field.1.to_byte()
    try @elf.parse(Bytes::from_array(copy)[:]) catch {
      Invalid(_) => ()
      e => fail("expected Invalid, got \{e}")
    } noraise {
      _ => fail("expected an error")
    }
  }
}

///|
test "names are limited and odd bytes become question marks" {
  let data = make_elf(needed=["lib\u{e9}.so"]).to_array()
  // The name is stored as UTF-16 code units cut to a byte by the builder, so
  // the 0xe9 byte is not printable ASCII.
  let info = @elf.parse(Bytes::from_array(data)[:])
  assert_eq(info.needed, ["lib?.so"])
  let long = "a".repeat(5000)
  try @elf.parse(make_elf(needed=[long])[:]) catch {
    Invalid(_) => ()
    e => fail("expected Invalid, got \{e}")
  } noraise {
    _ => fail("a name of 5000 bytes must be refused")
  }
}

///|
test "a library list without a string table is invalid" {
  // Replace the DT_STRTAB tag (5) by an unused one.
  let data = make_elf(needed=["libc.so.6"]).to_array()
  let mut changed = false
  // 64-bit little endian: dynamic entries are 16 bytes; find tag 5.
  let at = data.length() - 32
  if data[at] == 5 {
    data[at] = 0x70
    changed = true
  }
  assert_true(changed)
  try @elf.parse(Bytes::from_array(data)[:]) catch {
    Invalid(_) => ()
    e => fail("expected Invalid, got \{e}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "every cut of a file is an error or a smaller answer, never a crash" {
  let data = make_elf(
    interp=Some("/lib64/ld-linux-x86-64.so.2"),
    needed=["libc.so.6"],
    soname=Some("libz.so"),
  )
  for cut in 0..<data.length() {
    try @elf.parse(data[0:cut]) catch {
      _ => ()
    } noraise {
      _ => ()
    }
  }
  ignore(@elf.parse(data[:]))
}

///|
test "flipping any byte never crashes the reader" {
  for bits in [32, 64] {
    let data = make_elf(bits~, interp=Some("/lib/ld.so.1"), needed=[
      "libc.so.6", "libm.so.6",
    ]).to_array()
    for i in 0..<data.length() {
      for mask in [0x01, 0x80, 0xff] {
        let copy = data.copy()
        copy[i] = copy[i] ^ mask.to_byte()
        try @elf.parse(Bytes::from_array(copy)[:]) catch {
          _ => ()
        } noraise {
          _ => ()
        }
      }
    }
  }
}

///|
test "absurd sizes are refused without reading far" {
  // A dynamic segment that claims 2^40 bytes and program headers that start
  // at 2^62.
  let data = make_elf(needed=["libc.so.6"]).to_array()
  let a = data.copy()
  // e_phoff (offset 32, 8 bytes, little endian): set the top byte.
  a[39] = 0x40
  try @elf.parse(Bytes::from_array(a)[:]) catch {
    _ => ()
  } noraise {
    _ => fail("e_phoff of 2^62 must be refused")
  }
  let b = data.copy()
  b[39] = 0xff
  try @elf.parse(Bytes::from_array(b)[:]) catch {
    Invalid(_) => ()
    e => fail("expected Invalid for a value of 2^63 or more, got \{e}")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "JSON and text descriptions" {
  let info = @elf.parse(
    make_elf(machine=183, interp=Some("/lib/ld-linux-aarch64.so.1"), needed=[
      "libc.so.6",
    ])[:],
  )
  assert_eq(
    info.describe(),
    "ELF 64-bit LSB AArch64 (arm64), dynamic, interpreter /lib/ld-linux-aarch64.so.1, needs libc.so.6",
  )
  let json = info.to_json()
  guard json is Object(map) else { fail("object expected") }
  assert_eq(map.get("arch"), Some(Json::string("arm64")))
  assert_eq(map.get("linkage"), Some(Json::string("dynamic")))
  assert_eq(map.get("byte_order"), Some(Json::string("little")))
  assert_eq(map.get("needed"), Some(Json::array([Json::string("libc.so.6")])))
  assert_eq(map.get("soname"), Some(Json::null()))
  let unknown = @elf.parse(make_elf(machine=999)[:])
  assert_eq(unknown.describe(), "ELF 64-bit LSB machine 999, static")
  assert_eq(@elf.machine_name(3), "Intel 80386")
}

///|
test "summary: null, error object or the facts" {
  assert_eq(@elf.summary(b"text"), Json::null())
  guard @elf.summary(b"\x7fELF\x02\x01\x01") is Object(broken) else {
    fail("object expected")
  }
  assert_true(broken.get("error") is Some(String(_)))
  guard @elf.summary(make_elf()[:]) is Object(fine) else {
    fail("object expected")
  }
  assert_eq(fine.get("arch"), Some(Json::string("amd64")))
}

///|
test "real binaries made by the cross compilers agree with readelf" {
  for sample in samples {
    let (name, text, bits, little, interp, needed) = sample
    let data = @base64.decode(text)
    let info = @elf.parse(data[:])
    assert_eq(info.bits, bits)
    assert_eq(info.little_endian, little)
    assert_eq(info.interpreter, interp)
    assert_eq(info.needed, needed)
    let want_arch = name.split(".").last().unwrap().to_owned()
    assert_eq(info.arch(), Some(want_arch))
    let want_linkage : @elf.Linkage = if name.has_prefix("tiny.") {
      Static
    } else {
      Dynamic
    }
    assert_eq(info.linkage, want_linkage)
  }
}
