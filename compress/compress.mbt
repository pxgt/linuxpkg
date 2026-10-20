///|
/// A stream compression used inside packages.
///
/// `Lzma` (the old `.lzma` "alone" format) can only be read; nothing writes it.
pub(all) enum Compression {
  None
  Gzip
  Xz
  Zstd
  Lzma
} derive(Eq, Debug)

///|
/// The name used in configuration files and on the command line, such as
/// `"zstd"`.
pub fn Compression::name(self : Compression) -> String {
  match self {
    None => "none"
    Gzip => "gzip"
    Xz => "xz"
    Zstd => "zstd"
    Lzma => "lzma"
  }
}

///|
/// The file name suffix: `.gz`, `.xz`, `.zst`, `.lzma`, or empty for `None`.
pub fn Compression::extension(self : Compression) -> String {
  match self {
    None => ""
    Gzip => ".gz"
    Xz => ".xz"
    Zstd => ".zst"
    Lzma => ".lzma"
  }
}

///|
/// Parse a name written by a user. Only formats that can be produced are
/// accepted (`none`, `gzip`, `xz`, `zstd`); `gz` and `zst` are aliases.
///
/// # Example
/// ```mbt check
/// test {
///   assert_eq(@compress.Compression::parse("zstd"), Some(Zstd))
///   assert_eq(@compress.Compression::parse("lzma"), Option::None)
/// }
/// ```
pub fn Compression::parse(text : String) -> Compression? {
  match text {
    "none" => Some(None)
    "gzip" | "gz" => Some(Gzip)
    "xz" => Some(Xz)
    "zstd" | "zst" => Some(Zstd)
    _ => Option::None
  }
}

///|
/// Find the compression from a file name suffix such as `.zst` (`Lzma` for
/// `.lzma`). The empty suffix means `None`; any other suffix gives
/// `Option::None`.
pub fn Compression::from_extension(suffix : String) -> Compression? {
  match suffix {
    "" => Some(None)
    ".gz" => Some(Gzip)
    ".xz" => Some(Xz)
    ".zst" => Some(Zstd)
    ".lzma" => Some(Lzma)
    _ => Option::None
  }
}

///|
fn starts_with(data : BytesView, magic : Bytes) -> Bool {
  if data.length() < magic.length() {
    return false
  }
  for i in 0..<magic.length() {
    if data[i] != magic[i] {
      return false
    }
  }
  true
}

///|
/// Could these bytes be the header of a `.lzma` file? Checks the property
/// byte, the dictionary size (a power of two, or one and a half times one)
/// and the stored size.
fn looks_like_lzma(data : BytesView) -> Bool {
  if data.length() < 13 || data[0].to_int() >= 225 {
    return false
  }
  let props = data[0].to_int()
  if props % 9 + props / 9 % 5 > 4 {
    return false
  }
  let dict = data[1].to_uint64() |
    (data[2].to_uint64() << 8) |
    (data[3].to_uint64() << 16) |
    (data[4].to_uint64() << 24)
  let shaped = if dict == 0xFFFFFFFFUL {
    true
  } else if dict < 4096UL {
    false
  } else if (dict & (dict - 1UL)) == 0UL {
    true
  } else {
    let low = dict & (0UL - dict)
    let rest = dict - low
    (rest & (rest - 1UL)) == 0UL && low == rest / 2UL
  }
  if !shaped {
    return false
  }
  // The stored size is either "unknown" (all ones) or well below 2^38.
  let mut size = 0UL
  for i in 0..<8 {
    size = size | (data[5 + i].to_uint64() << (8 * i))
  }
  size == 0xFFFFFFFFFFFFFFFFUL || size < 1UL << 38
}

///|
/// Recognise the compression of a stream by its first bytes. Anything that
/// carries no known signature is reported as `None`.
///
/// # Example
/// ```mbt check
/// test {
///   let packed = @compress.compress(b"hello", Xz)
///   assert_eq(@compress.detect(packed), Xz)
///   assert_eq(@compress.detect(b"plain"), None)
/// }
/// ```
pub fn detect(data : BytesView) -> Compression {
  if starts_with(data, b"\x1f\x8b") {
    Gzip
  } else if starts_with(data, b"\xfd7zXZ\x00") {
    Xz
  } else if starts_with(data, b"\x28\xb5\x2f\xfd") {
    Zstd
  } else if looks_like_lzma(data) {
    Lzma
  } else {
    None
  }
}

///|
const ZSTD_LEVEL : Int32 = 9

///|
const CHUNK : Int32 = 65536

///|
/// Largest dictionary the xz and lzma decoders will allocate.
const XZ_MEMLIMIT : UInt64 = 268435456UL

///|
/// Compress `data`. Gzip uses the pure-MoonBit flate package, xz the
/// lzma-mbt encoder at its default preset and zstd level 9 (see
/// `docs/formats.md` for the measured ratios). The output depends only on
/// the input, so builds stay reproducible. `Lzma` cannot be written.
pub fn compress(
  data : BytesView,
  compression : Compression,
) -> Bytes raise CompressError {
  match compression {
    None => data.to_owned()
    Gzip => @gzip.compress(data.to_owned())
    Xz =>
      @lzma.encode(data, options={
        ..@lzma.EncodeOptions::default(),
        format: @lzma.Format::Xz,
      }) catch {
        _ => raise Corrupt("xz: the encoder failed")
      }
    Zstd =>
      @zstd.compress(data.to_owned(), level=ZSTD_LEVEL, checksum=true) catch {
        _ => raise Corrupt("zstd: the encoder failed")
      }
    Lzma => raise Unsupported("lzma: writing .lzma files is not supported")
  }
}

///|
fn unzip(data : BytesView, max_size : Int32) -> Bytes raise CompressError {
  if data.length() == 0 {
    raise Corrupt("gzip: input too short")
  }
  let decoder = @gzip.Decoder()
  let out = Buffer(size_hint=1024)
  let chunk : FixedArray[Byte] = FixedArray::make(CHUNK, b'\x00')
  let mut pos = 0
  while true {
    let status = decoder.step_into(data[pos:], chunk, end=true) catch {
      @gzip.GzipError::GzipError(_, message) =>
        raise Corrupt(
          if message.has_prefix("gzip") {
            message
          } else {
            "gzip: \{message}"
          },
        )
    }
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    pos += consumed
    if out.length() + produced > max_size {
      raise TooLarge(max_size)
    }
    out.write_bytes(Bytes::from_array(chunk[0:produced]))
    match status {
      Done => break
      NeedMoreInput => raise Corrupt("gzip: input too short")
      NeedMoreOutput =>
        if produced == 0 && consumed == 0 {
          raise Corrupt("gzip: decoder made no progress")
        }
    }
  }
  out.to_bytes()
}

///|
fn unxz(data : BytesView, max_size : Int32) -> Bytes raise CompressError {
  // The decoder works on a whole block at once, so the size is measured
  // from the block structure first and a bomb never gets that far.
  let total = xz_unpacked_size(data)
  if total > max_size.to_uint64() {
    raise TooLarge(max_size)
  }
  let out = @lzma.decode(data, options={
    ..@lzma.DecodeOptions::default(),
    format: @lzma.Format::Xz,
    memlimit: Some(XZ_MEMLIMIT),
    concatenated: true,
  }) catch {
    MemoryLimit =>
      raise Unsupported("xz: the dictionary is larger than 256 MiB")
    UnsupportedFeature(message) => raise Unsupported("xz: \{message}")
    _ => raise Corrupt("xz: the stream is damaged")
  }
  if out.length() > max_size {
    raise TooLarge(max_size)
  }
  out
}

///|
fn unzstd(data : BytesView, max_size : Int32) -> Bytes raise CompressError {
  if data.length() == 0 {
    raise Corrupt("zstd: input too short")
  }
  let bytes = data.to_owned()
  let bound = @zstd.decompress_bound(bytes) catch {
    _ => raise Corrupt("zstd: the stream is damaged")
  }
  if bound > max_size.to_uint64() {
    raise TooLarge(max_size)
  }
  let out = @zstd.decompress(bytes) catch {
    UnsupportedFeature(message) => raise Unsupported("zstd: \{message}")
    DictionaryRequired(_) =>
      raise Unsupported("zstd: the stream needs a dictionary")
    _ => raise Corrupt("zstd: the stream is damaged")
  }
  if out.length() > max_size {
    raise TooLarge(max_size)
  }
  out
}

///|
fn unlzma(data : BytesView, max_size : Int32) -> Bytes raise CompressError {
  if data.length() < 13 {
    raise Corrupt("lzma: input too short")
  }
  let mut size = 0UL
  for i in 0..<8 {
    size = size | (data[5 + i].to_uint64() << (8 * i))
  }
  if size == 0xFFFFFFFFFFFFFFFFUL {
    // No stored size: the output cannot be measured beforehand, so only
    // inputs whose largest possible expansion fits the limit are unpacked.
    if data.length().to_uint64() * 4096UL > max_size.to_uint64() {
      raise Unsupported(
        "lzma: a stream without a stored size is too large to unpack safely",
      )
    }
  } else if size > max_size.to_uint64() {
    raise TooLarge(max_size)
  }
  let out = @lzma.decode(data, options={
    ..@lzma.DecodeOptions::default(),
    format: @lzma.Format::Lzma,
    memlimit: Some(XZ_MEMLIMIT),
  }) catch {
    MemoryLimit =>
      raise Unsupported("lzma: the dictionary is larger than 256 MiB")
    _ => raise Corrupt("lzma: the stream is damaged")
  }
  if out.length() > max_size {
    raise TooLarge(max_size)
  }
  out
}

///|
/// Unpack a stream of the given compression, refusing to produce more than
/// `max_size` bytes. A small hostile input therefore cannot exhaust memory:
/// gzip stops as soon as the limit is crossed; xz and zstd measure the
/// unpacked size from the stream structure before decoding anything.
///
/// # Example
/// ```mbt check
/// test {
///   let packed = @compress.compress(b"hello", Zstd)
///   assert_eq(@compress.decompress(packed, Zstd, max_size=100), b"hello")
/// }
/// ```
pub fn decompress(
  data : BytesView,
  compression : Compression,
  max_size~ : Int32 = 1073741824,
) -> Bytes raise CompressError {
  match compression {
    None =>
      if data.length() > max_size {
        raise TooLarge(max_size)
      } else {
        data.to_owned()
      }
    Gzip => unzip(data, max_size)
    Xz => unxz(data, max_size)
    Zstd => unzstd(data, max_size)
    Lzma => unlzma(data, max_size)
  }
}
