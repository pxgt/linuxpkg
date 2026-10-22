///|
/// Is the file linked statically or does it need a dynamic linker?
///
/// `Dynamic` when the file asks for an interpreter (`PT_INTERP`) or lists
/// shared libraries (`DT_NEEDED`) or names itself (`DT_SONAME`). A
/// static-pie executable has a `.dynamic` segment but none of these, so it
/// counts as `Static`, which is also what `file` calls it.
pub(all) enum Linkage {
  Static
  Dynamic
} derive(Eq, Debug)

///|
/// What the headers of an ELF file say.
///
/// `machine` is the `e_machine` number, `flags` is `e_flags`, `file_type` is
/// `e_type` (1 relocatable, 2 executable, 3 shared object or PIE, 4 core).
/// `interpreter`, `needed` and `soname` come from the program headers and
/// the `.dynamic` segment; section headers are never read, so a stripped
/// file gives the same answer as an unstripped one.
pub(all) struct ElfInfo {
  bits : Int32
  little_endian : Bool
  file_type : Int32
  machine : Int32
  flags : Int32
  linkage : Linkage
  interpreter : String?
  needed : Array[String]
  soname : String?
} derive(Eq, Debug)

///|
const MAX_NAME : Int32 = 4096

///|
const MAX_DYNAMIC_ENTRIES : Int64 = 16384L

///|
priv struct Reader {
  data : BytesView
  little : Bool
}

///|
fn Reader::check(
  self : Reader,
  at : Int64,
  size : Int32,
  what : String,
) -> Unit raise ElfError {
  if at < 0L || at + size.to_int64() > self.data.length().to_int64() {
    raise Truncated(what)
  }
}

///|
fn Reader::u16(
  self : Reader,
  at : Int64,
  what : String,
) -> Int32 raise ElfError {
  self.check(at, 2, what)
  let i = at.to_int()
  let a = self.data[i].to_int()
  let b = self.data[i + 1].to_int()
  if self.little {
    a | (b << 8)
  } else {
    (a << 8) | b
  }
}

///|
/// An unsigned 32-bit field, returned as a non-negative `Int64`.
fn Reader::u32(
  self : Reader,
  at : Int64,
  what : String,
) -> Int64 raise ElfError {
  self.check(at, 4, what)
  let i = at.to_int()
  let mut value = 0L
  for k in 0..<4 {
    let byte = self.data[if self.little { i + 3 - k } else { i + k }]
    value = (value << 8) | byte.to_int64()
  }
  value
}

///|
/// A 64-bit field. Values of 2^63 and above are refused: no real file has
/// an offset or an address that large.
fn Reader::u64(
  self : Reader,
  at : Int64,
  what : String,
) -> Int64 raise ElfError {
  self.check(at, 8, what)
  let i = at.to_int()
  let mut value = 0L
  for k in 0..<8 {
    let byte = self.data[if self.little { i + 7 - k } else { i + k }]
    value = (value << 8) | byte.to_int64()
  }
  if value < 0L {
    raise Invalid("a \{what} field is larger than 2^63")
  }
  value
}

///|
/// A field that is 4 bytes wide in a 32-bit file and 8 bytes in a 64-bit one.
fn Reader::word(
  self : Reader,
  at : Int64,
  bits : Int32,
  what : String,
) -> Int64 raise ElfError {
  if bits == 64 {
    self.u64(at, what)
  } else {
    self.u32(at, what)
  }
}

///|
priv struct Segment {
  offset : Int64
  vaddr : Int64
  size : Int64
}

///|
/// The NUL-terminated text at `at`, at most `MAX_NAME` bytes. Bytes outside
/// printable ASCII become `?` so the result is the same on every backend.
fn read_text(
  data : BytesView,
  at : Int64,
  what : String,
) -> String raise ElfError {
  if at < 0L || at >= data.length().to_int64() {
    raise Truncated(what)
  }
  let out = StringBuilder()
  let mut i = at.to_int()
  let mut length = 0
  while true {
    if i >= data.length() {
      raise Truncated(what)
    }
    let byte = data[i].to_int()
    if byte == 0 {
      break
    }
    if length >= MAX_NAME {
      raise Invalid("a \{what} is longer than \{MAX_NAME} bytes")
    }
    if byte >= 0x20 && byte < 0x7f {
      out.write_char(byte.unsafe_to_char())
    } else {
      out.write_char('?')
    }
    i = i + 1
    length = length + 1
  }
  out.to_string()
}

///|
/// Does the data start with the ELF magic number?
///
/// # Example
/// ```mbt check
/// test {
///   assert_true(@elf.is_elf(b"\x7fELF\x02\x01\x01"))
///   assert_false(@elf.is_elf(b"#!/bin/sh\n"))
/// }
/// ```
pub fn is_elf(data : BytesView) -> Bool {
  data.length() >= 4 &&
  data[0] == b'\x7f' &&
  data[1] == b'E' &&
  data[2] == b'L' &&
  data[3] == b'F'
}

///|
/// Read the headers of an ELF file (32 or 64 bit, either byte order).
///
/// Only the file header, the program headers and the `.dynamic` segment are
/// read. Any damage gives an `ElfError`, never a crash or an unbounded loop.
pub fn parse(data : BytesView) -> ElfInfo raise ElfError {
  if !is_elf(data) {
    raise NotElf
  }
  if data.length() < 16 {
    raise Truncated("identification")
  }
  let bits = match data[4].to_int() {
    1 => 32
    2 => 64
    other => raise Invalid("unknown class \{other} (expected 1 or 2)")
  }
  let little = match data[5].to_int() {
    1 => true
    2 => false
    other => raise Invalid("unknown byte order \{other} (expected 1 or 2)")
  }
  let r : Reader = { data, little, }
  let is64 = bits == 64
  let file_type = r.u16(16L, "file header")
  let machine = r.u16(18L, "file header")
  let flags = r.u32(if is64 { 48L } else { 36L }, "file header").to_int()
  let phoff = r.word(if is64 { 32L } else { 28L }, bits, "file header")
  let phentsize = r.u16(if is64 { 54L } else { 42L }, "file header")
  let phnum = r.u16(if is64 { 56L } else { 44L }, "file header")
  let mut interpreter : String? = None
  let needed : Array[String] = []
  let mut soname : String? = None
  if phnum != 0 {
    if phnum == 0xffff {
      raise Invalid("more than 65534 program headers are not supported")
    }
    let minimum = if is64 { 56 } else { 32 }
    if phentsize < minimum {
      raise Invalid(
        "program header size \{phentsize} is smaller than \{minimum}",
      )
    }
    r.check(phoff, phnum * phentsize, "program headers")
    let loads : Array[Segment] = []
    let mut interp_segment : Segment? = None
    let mut dynamic_segment : Segment? = None
    for i in 0..<phnum {
      let at = phoff + (i * phentsize).to_int64()
      let kind = r.u32(at, "program headers")
      let segment : Segment = if is64 {
        {
          offset: r.u64(at + 8L, "program headers"),
          vaddr: r.u64(at + 16L, "program headers"),
          size: r.u64(at + 32L, "program headers"),
        }
      } else {
        {
          offset: r.u32(at + 4L, "program headers"),
          vaddr: r.u32(at + 8L, "program headers"),
          size: r.u32(at + 16L, "program headers"),
        }
      }
      match kind {
        1L => loads.push(segment)
        2L => if dynamic_segment is None { dynamic_segment = Some(segment) }
        3L => if interp_segment is None { interp_segment = Some(segment) }
        _ => ()
      }
    }
    if interp_segment is Some(segment) {
      interpreter = Some(read_text(data, segment.offset, "interpreter path"))
      if segment.offset + segment.size > data.length().to_int64() {
        raise Truncated("interpreter path")
      }
    }
    if dynamic_segment is Some(segment) {
      let entry = if is64 { 16L } else { 8L }
      let count = segment.size / entry
      if count > MAX_DYNAMIC_ENTRIES {
        raise Invalid(
          "the dynamic section has more than \{MAX_DYNAMIC_ENTRIES} entries",
        )
      }
      r.check(segment.offset, (count * entry).to_int(), "dynamic section")
      let needed_offsets : Array[Int64] = []
      let mut soname_offset : Int64? = None
      let mut strtab : Int64? = None
      for i in 0L..<count {
        let at = segment.offset + i * entry
        let tag = r.word(at, bits, "dynamic section")
        let value = r.word(at + entry / 2L, bits, "dynamic section")
        match tag {
          0L => break
          1L => needed_offsets.push(value)
          5L => strtab = Some(value)
          14L => soname_offset = Some(value)
          _ => ()
        }
      }
      if needed_offsets.length() > 0 || soname_offset is Some(_) {
        let address = match strtab {
          Some(address) => address
          None =>
            raise Invalid(
              "the dynamic section names libraries but has no string table",
            )
        }
        let mut table : Int64? = None
        for load in loads {
          if table is None &&
            address >= load.vaddr &&
            address < load.vaddr + load.size {
            table = Some(load.offset + (address - load.vaddr))
          }
        }
        let base = match table {
          Some(base) => base
          None =>
            raise Invalid("the string table is not inside a loaded segment")
        }
        for offset in needed_offsets {
          needed.push(read_text(data, base + offset, "library name"))
        }
        if soname_offset is Some(offset) {
          soname = Some(read_text(data, base + offset, "library name"))
        }
      }
    }
  }
  let linkage = if interpreter is Some(_) ||
    needed.length() > 0 ||
    soname is Some(_) {
    Dynamic
  } else {
    Static
  }
  {
    bits,
    little_endian: little,
    file_type,
    machine,
    flags,
    linkage,
    interpreter,
    needed,
    soname,
  }
}

///|
/// The package architecture this file runs on, spelled the way
/// `@spec.Arch::parse` accepts it (`amd64`, `arm64`, `i386`, `armhf`, `armel`,
/// `ppc64le`, `s390x`, `riscv64`, `loong64`, `mips64le`), or `None` for
/// machines without such a package architecture (other CPUs, big-endian
/// variants, x32 and n32 style ABIs).
///
/// ARM 32-bit is `armhf` when the hard-float flag (`EF_ARM_ABI_FLOAT_HARD`,
/// 0x400) is set in `e_flags` and `armel` otherwise.
pub fn ElfInfo::arch(self : ElfInfo) -> String? {
  match (self.machine, self.bits, self.little_endian) {
    (62, 64, true) => Some("amd64")
    (183, 64, true) => Some("arm64")
    (3, 32, true) => Some("i386")
    (243, 64, true) => Some("riscv64")
    (258, 64, true) => Some("loong64")
    (22, 64, false) => Some("s390x")
    (21, 64, true) => Some("ppc64le")
    (8, 64, true) => Some("mips64le")
    (40, 32, true) =>
      if (self.flags & 0x400) != 0 {
        Some("armhf")
      } else {
        Some("armel")
      }
    _ => None
  }
}

///|
/// A short name for `e_machine`, like `readelf -h` prints it.
pub fn machine_name(machine : Int32) -> String {
  match machine {
    3 => "Intel 80386"
    8 => "MIPS"
    20 => "PowerPC"
    21 => "PowerPC64"
    22 => "IBM S/390"
    40 => "ARM"
    62 => "x86-64"
    183 => "AArch64"
    243 => "RISC-V"
    258 => "LoongArch"
    other => "machine \{other}"
  }
}

///|
fn type_name(file_type : Int32) -> String {
  match file_type {
    1 => "relocatable"
    2 => "executable"
    3 => "shared object or PIE"
    4 => "core"
    other => "type \{other}"
  }
}

///|
/// The facts as JSON, the way `inspect --json` shows them for each ELF file
/// of a package.
pub fn ElfInfo::to_json(self : ElfInfo) -> Json {
  let arch : Json = match self.arch() {
    Some(name) => Json::string(name)
    None => Json::null()
  }
  let interpreter : Json = match self.interpreter {
    Some(path) => Json::string(path)
    None => Json::null()
  }
  let soname : Json = match self.soname {
    Some(name) => Json::string(name)
    None => Json::null()
  }
  Json::object({
    "arch": arch,
    "machine": Json::number(self.machine.to_double()),
    "machine_name": Json::string(machine_name(self.machine)),
    "bits": Json::number(self.bits.to_double()),
    "byte_order": Json::string(
      if self.little_endian {
        "little"
      } else {
        "big"
      },
    ),
    "type": Json::string(type_name(self.file_type)),
    "linkage": Json::string(
      match self.linkage {
        Static => "static"
        Dynamic => "dynamic"
      },
    ),
    "interpreter": interpreter,
    "needed": Json::array(self.needed.map(Json::string)),
    "soname": soname,
  })
}

///|
/// One line for text output, for example
/// `ELF 64-bit LSB AArch64 (arm64), dynamic, interpreter /lib/ld-linux-aarch64.so.1, needs libc.so.6`.
pub fn ElfInfo::describe(self : ElfInfo) -> String {
  let order = if self.little_endian { "LSB" } else { "MSB" }
  let arch = match self.arch() {
    Some(name) => " (\{name})"
    None => ""
  }
  let linkage = match self.linkage {
    Static => "static"
    Dynamic => "dynamic"
  }
  let out = StringBuilder()
  out.write_string(
    "ELF \{self.bits}-bit \{order} \{machine_name(self.machine)}\{arch}, \{linkage}",
  )
  if self.interpreter is Some(path) {
    out.write_string(", interpreter \{path}")
  }
  if self.needed.length() > 0 {
    let libraries = self.needed.join(", ")
    out.write_string(", needs \{libraries}")
  }
  out.to_string()
}

///|
/// The `"elf"` entry of a file in `inspect --json`: `null` for data that is not
/// an ELF file, `{"error": ...}` when it starts like one but cannot be read,
/// and `ElfInfo::to_json` otherwise.
pub fn summary(data : BytesView) -> Json {
  if !is_elf(data) {
    return Json::null()
  }
  try parse(data) catch {
    err => Json::object({ "error": Json::string("\{err}") })
  } noraise {
    info => info.to_json()
  }
}
