///|
/// A deb opened for inspection: its control data and its file tree.
pub(all) struct DebPackage {
  /// Contents of `debian-binary`, for example `2.0`.
  format_version : String
  /// Fields of the `control` file in file order.
  fields : Array[(String, String)]
  /// Every file of `control.tar`: control, md5sums, conffiles, scripts, ...
  control_files : Array[(String, Bytes)]
  /// The entries of `data.tar`, with their paths as stored.
  files : Array[@tar.Entry]
  /// `(absolute path, hex digest)` pairs of the `md5sums` file.
  md5sums : Array[(String, String)]
  /// Absolute paths listed in `conffiles`.
  conffiles : Array[String]
  /// `none`, `gzip`, `xz`, `zstd` or `lzma`.
  control_compression : String
  data_compression : String
} derive(Eq, Debug)

///|
/// How a part is compressed, judging by the extension after `.tar`.
fn compression_of(
  part : String,
  base : String,
) -> @compress.Compression raise DebError {
  let suffix = part[base.length():].to_owned()
  match @compress.Compression::from_extension(suffix) {
    Some(compression) => compression
    None =>
      if suffix == ".bz2" {
        raise DebError::Unsupported(
          message="\{part}: bzip2 compression is not supported (use gzip, xz, zstd, lzma or no compression)",
        )
      } else {
        raise DebError::Unsupported(
          message="\{part}: unknown compression \"\{suffix}\" (supported: gzip, xz, zstd, lzma, none)",
        )
      }
  }
}

///|
fn unpack(
  part : @ar.Member,
  compression : @compress.Compression,
  max_unpacked : Int32,
) -> Bytes raise DebError {
  @compress.decompress(part.data, compression, max_size=max_unpacked) catch {
    Corrupt(message) =>
      raise DebError::Corrupt(message="\{part.name}: \{message}")
    TooLarge(_) =>
      raise DebError::Corrupt(
        message="\{part.name} unpacks to more than \{max_unpacked} bytes",
      )
    Unsupported(message) =>
      raise DebError::Unsupported(message="\{part.name}: \{message}")
  }
}

///|
fn read_tar(name : String, data : Bytes) -> Array[@tar.Entry] raise DebError {
  @tar.parse(data) catch {
    @tar.TarError::Unsupported(message~) =>
      raise DebError::Unsupported(message="\{name}: \{message}")
    err => raise DebError::Corrupt(message="\{name}: \{err}")
  }
}

///|
/// `./usr/bin/hello` and `usr/bin/hello/` both become `/usr/bin/hello`; the
/// archive root becomes `/`.
pub fn normalize_path(path : String) -> String {
  let mut p = path
  while p.has_prefix("./") {
    p = p[2:].to_owned()
  }
  if p == "." {
    p = ""
  }
  while p.length() > 0 && p.has_suffix("/") {
    p = p[0:p.length() - 1].to_owned()
  }
  if p.has_prefix("/") {
    p
  } else {
    "/" + p
  }
}

///|
/// Open a `.deb`: split the ar container, unpack the control and data
/// archives (gzip, xz, zstd, lzma or uncompressed) and parse the control
/// information. Other compressions (bzip2) are reported as `Unsupported`.
/// `max_unpacked` bounds the size of each unpacked archive.
pub fn read(
  deb : BytesView,
  max_unpacked~ : Int32 = 1073741824,
) -> DebPackage raise DebError {
  let members = @ar.parse(deb) catch {
    @ar.ArError::Corrupt(offset~, message~) =>
      raise DebError::Corrupt(message="ar offset \{offset}: \{message}")
    err => raise DebError::Corrupt(message="\{err}")
  }
  if members.length() == 0 || members[0].name != "debian-binary" {
    raise DebError::Corrupt(
      message="the first ar member must be debian-binary, this is not a deb",
    )
  }
  let format_version = @utf8.decode_lossy(members[0].data).trim().to_owned()
  if !format_version.has_prefix("2.") {
    raise DebError::Unsupported(
      message="deb format version \"\{format_version}\" (only 2.x is supported)",
    )
  }
  let mut control_member : @ar.Member? = None
  let mut data_member : @ar.Member? = None
  for part in members {
    if part.name.has_prefix("control.tar") && control_member is None {
      control_member = Some(part)
    } else if part.name.has_prefix("data.tar") && data_member is None {
      data_member = Some(part)
    }
  }
  let control_member = match control_member {
    Some(m) => m
    None => raise DebError::Corrupt(message="control.tar member is missing")
  }
  let data_member = match data_member {
    Some(m) => m
    None => raise DebError::Corrupt(message="data.tar member is missing")
  }
  let control_compression = compression_of(control_member.name, "control.tar")
  let data_compression = compression_of(data_member.name, "data.tar")
  let control_tar = read_tar(
    control_member.name,
    unpack(control_member, control_compression, max_unpacked),
  )
  let control_files : Array[(String, Bytes)] = []
  for entry in control_tar {
    match entry.kind {
      File(content) => {
        let name = normalize_path(entry.path)[1:].to_owned()
        control_files.push((name, content))
      }
      _ => ()
    }
  }
  let find = (name : String) => {
    for item in control_files {
      if item.0 == name {
        return Some(item.1)
      }
    }
    None
  }
  let fields = match find("control") {
    Some(content) => parse_control(@utf8.decode_lossy(content))
    None => raise DebError::Corrupt(message="control.tar has no control file")
  }
  let md5sums = match find("md5sums") {
    Some(content) => parse_md5sums(@utf8.decode_lossy(content))
    None => []
  }
  let conffiles : Array[String] = []
  match find("conffiles") {
    Some(content) =>
      for line in @utf8.decode_lossy(content).split("\n") {
        let line = line.trim().to_owned()
        if line.length() > 0 {
          conffiles.push(line)
        }
      }
    None => ()
  }
  let files = read_tar(
    data_member.name,
    unpack(data_member, data_compression, max_unpacked),
  )
  {
    format_version,
    fields,
    control_files,
    files,
    md5sums,
    conffiles,
    control_compression: control_compression.name(),
    data_compression: data_compression.name(),
  }
}

///|
/// The value of a control field, matched without regard to case.
pub fn DebPackage::field(self : DebPackage, name : String) -> String? {
  let wanted = name.to_lower()
  for field in self.fields {
    if field.0.to_lower() == wanted {
      return Some(field.1)
    }
  }
  None
}
