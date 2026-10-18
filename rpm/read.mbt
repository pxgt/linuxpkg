///|
/// An rpm opened for inspection. The payload is kept compressed; only
/// `payload_entries` and `verify` unpack it.
pub(all) struct RpmPackage {
  /// The package label stored in the 96-byte lead (`name-version-release`).
  lead_name : String
  signature : Header
  header : Header
  /// The exact bytes of the main header, which the signature digests cover.
  header_bytes : Bytes
  /// The payload as stored, still compressed.
  payload : Bytes
} derive(Eq, Debug)

///|
/// One file of the package as the header describes it.
pub(all) struct RpmFile {
  /// Absolute install path.
  path : String
  /// Complete `st_mode` including the file type bits.
  mode : Int32
  size : Int64
  mtime : Int64
  /// Hex digest of the content, empty for directories and links.
  digest : String
  /// Symbolic link target, empty otherwise.
  link : String
  owner : String
  group : String
  /// `RPMFILE_*` flags; bit 0 is a configuration file.
  flags : Int32
} derive(Eq, Debug)

///|
/// Open an rpm: parse the lead, the signature header and the main header.
/// Nothing is decompressed, so packages with xz or zstd payloads can be
/// inspected too.
pub fn read(bytes : BytesView) -> RpmPackage raise RpmError {
  if bytes.length() < 96 {
    raise RpmError::Corrupt(
      offset=0,
      message="file is \{bytes.length()} bytes long, shorter than the 96 byte lead",
    )
  }
  if bytes[0:4].to_owned() != b"\xed\xab\xee\xdb" {
    raise RpmError::Corrupt(
      offset=0,
      message="missing rpm magic, this is not an rpm",
    )
  }
  if bytes[4] != b'\x03' {
    raise RpmError::Unsupported(
      message="rpm lead version \{bytes[4].to_int()}.\{bytes[5].to_int()} (only 3.x is supported)",
    )
  }
  let mut label_end = 10
  while label_end < 76 && bytes[label_end] != b'\x00' {
    label_end += 1
  }
  let lead_name = @utf8.decode_lossy(bytes[10:label_end])
  let (signature, signature_end) = Header::decode(bytes, 96)
  let main_start = (signature_end + 7) / 8 * 8
  if main_start >= bytes.length() {
    raise RpmError::Corrupt(
      offset=signature_end,
      message="the main header is missing",
    )
  }
  let (header, main_end) = Header::decode(bytes, main_start)
  {
    lead_name,
    signature,
    header,
    header_bytes: bytes[main_start:main_end].to_owned(),
    payload: bytes[main_end:].to_owned(),
  }
}

///|
fn unsigned32(value : Int32) -> Int64 {
  if value < 0 {
    value.to_int64() + 4294967296L
  } else {
    value.to_int64()
  }
}

///|
/// Integer values of a tag as 64-bit numbers; 32-bit values are read as
/// unsigned.
fn Header::numbers(self : Header, id : Int32) -> Array[Int64] {
  match self.get(id) {
    Some(Int64(items)) => items
    Some(Int32(items)) => items.map(unsigned32)
    Some(Int16(items)) | Some(Int8(items)) => items.map(v => v.to_int64())
    _ => []
  }
}

///|
/// The name of the payload compressor (`gzip`, `xz`, `zstd`, ...); `gzip` is
/// the rpm default when the tag is absent.
pub fn RpmPackage::compressor(self : RpmPackage) -> String {
  match self.header.string(1125) {
    Some(name) => name
    None => "gzip"
  }
}

///|
/// The files the header lists, in package order.
pub fn RpmPackage::files(self : RpmPackage) -> Array[RpmFile] raise RpmError {
  let h = self.header
  let base = h.strings(1117)
  let dirs = h.strings(1118)
  let indexes = h.ints(1116)
  let count = base.length()
  if count == 0 {
    return []
  }
  if indexes.length() != count {
    raise RpmError::Corrupt(
      offset=-1,
      message="\{count} base names but \{indexes.length()} directory indexes",
    )
  }
  let sizes = if h.get(5008) is Some(_) {
    h.numbers(5008)
  } else {
    h.numbers(1028)
  }
  let modes = h.ints(1030)
  let mtimes = h.numbers(1034)
  let digests = h.strings(1035)
  let links = h.strings(1036)
  let owners = h.strings(1039)
  let groups = h.strings(1040)
  let flags = h.ints(1037)
  for
    pair in [
      ("sizes", sizes.length()),
      ("modes", modes.length()),
      ("mtimes", mtimes.length()),
      ("digests", digests.length()),
      ("link targets", links.length()),
      ("owners", owners.length()),
      ("groups", groups.length()),
    ] {
    if pair.1 != count {
      raise RpmError::Corrupt(
        offset=-1,
        message="\{count} files but \{pair.1} \{pair.0}",
      )
    }
  }
  let files : Array[RpmFile] = []
  for i in 0..<count {
    let dir_index = indexes[i]
    if dir_index < 0 || dir_index >= dirs.length() {
      raise RpmError::Corrupt(
        offset=-1,
        message="file \{i} uses directory index \{dir_index} of \{dirs.length()}",
      )
    }
    files.push({
      path: dirs[dir_index] + base[i],
      mode: modes[i],
      size: sizes[i],
      mtime: mtimes[i],
      digest: digests[i],
      link: links[i],
      owner: owners[i],
      group: groups[i],
      flags: if i < flags.length() {
        flags[i]
      } else {
        0
      },
    })
  }
  files
}

///|
/// Decompress the payload. Raises `Unsupported` for payload formats or
/// compressors other than cpio with gzip or no compression.
fn RpmPackage::raw_payload(
  self : RpmPackage,
  max_unpacked : Int32,
) -> Bytes raise RpmError {
  match self.header.string(1124) {
    Some("cpio") | None => ()
    Some(other) =>
      raise RpmError::Unsupported(
        message="payload format \"\{other}\" (only cpio is supported)",
      )
  }
  let raw = match self.compressor() {
    "gzip" =>
      @gunzip.decompress(self.payload, max_size=max_unpacked) catch {
        Corrupt(message) =>
          raise RpmError::Corrupt(offset=-1, message="payload: \{message}")
        TooLarge(_) =>
          raise RpmError::Corrupt(
            offset=-1,
            message="payload unpacks to more than \{max_unpacked} bytes",
          )
      }
    "identity" | "" => self.payload
    other =>
      raise RpmError::Unsupported(
        message="\{other} compression of the payload is not supported (only gzip and uncompressed payloads)",
      )
  }
  if raw.length() > max_unpacked {
    raise RpmError::Corrupt(
      offset=-1,
      message="payload unpacks to more than \{max_unpacked} bytes",
    )
  }
  raw
}

///|
/// Decompress and parse the cpio payload. Raises `Unsupported` for payload
/// formats or compressors other than cpio with gzip or no compression.
pub fn RpmPackage::payload_entries(
  self : RpmPackage,
  max_unpacked~ : Int32 = 1073741824,
) -> Array[@cpio.Entry] raise RpmError {
  let raw = self.raw_payload(max_unpacked)
  @cpio.parse(raw) catch {
    err => raise RpmError::Corrupt(offset=-1, message="payload: \{err}")
  }
}

///|
/// The tag as a string, or "" when it is absent.
fn Header::text(self : Header, id : Int32) -> String {
  match self.string(id) {
    Some(text) => text
    None => ""
  }
}
