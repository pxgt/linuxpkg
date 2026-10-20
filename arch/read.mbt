///|
/// One line of `.MTREE`, with the `/set` defaults already applied.
pub(all) struct MtreeEntry {
  /// Path relative to `/`, without `./` and without a trailing slash.
  path : String
  /// `file`, `dir` or `link` (the mtree `type`).
  kind : String
  /// Permission bits.
  mode : Int32?
  size : Int64?
  sha256 : String?
  link : String?
} derive(Eq, Debug)

///|
/// An Arch Linux package opened for inspection: its `.PKGINFO`, `.MTREE`,
/// `.INSTALL` and the tar entries.
pub(all) struct ArchPackage {
  /// `zstd`, `xz`, `gzip`, `lzma` or `none`.
  compression : String
  /// `.PKGINFO` as `(key, value)` pairs in file order.
  pkginfo : Array[(String, String)]
  /// The text of `.INSTALL`, when the package has one.
  install : String?
  /// The parsed `.MTREE`, when the package has one.
  mtree : Array[MtreeEntry]?
  /// Every entry of the tar archive in order, metadata files included.
  entries : Array[@tar.Entry]
} derive(Eq, Debug)

///|
/// `./usr/bin/` and `usr/bin` both become `usr/bin`.
fn clean_path(path : String) -> String {
  let mut p = path
  while p.has_prefix("./") {
    p = p[2:].to_owned()
  }
  while p.length() > 0 && p.has_suffix("/") {
    p = p[0:p.length() - 1].to_owned()
  }
  p
}

///|
fn is_metadata(path : String) -> Bool {
  match path {
    ".PKGINFO" | ".MTREE" | ".INSTALL" | ".BUILDINFO" | ".CHANGELOG" => true
    _ => false
  }
}

///|
fn parse_pkginfo(text : String) -> Array[(String, String)] {
  let fields : Array[(String, String)] = []
  for line in text.split("\n") {
    let line = line.trim().to_owned()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    match line.find(" = ") {
      Some(at) => fields.push((line[0:at].to_owned(), line[at + 3:].to_owned()))
      None =>
        match line.find("=") {
          Some(at) =>
            fields.push(
              (line[0:at].trim().to_owned(), line[at + 1:].trim().to_owned()),
            )
          None => ()
        }
    }
  }
  fields
}

///|
fn digit_value(c : Char) -> Int32? {
  if c is ('0'..<='7') {
    Some(c.to_int() - 48)
  } else {
    None
  }
}

///|
/// Undo mtree's `\ooo` escapes.
fn mtree_unquote(text : String) -> String {
  let bytes = @utf8.encode(text)
  let out : Array[Byte] = []
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == b'\\' && i + 3 < bytes.length() + 0 {
      let a = digit_value(bytes[i + 1].to_int().unsafe_to_char())
      let b = digit_value(bytes[i + 2].to_int().unsafe_to_char())
      let c = digit_value(bytes[i + 3].to_int().unsafe_to_char())
      match (a, b, c) {
        (Some(x), Some(y), Some(z)) => {
          out.push((x * 64 + y * 8 + z).to_byte())
          i += 4
          continue
        }
        _ => ()
      }
    }
    out.push(bytes[i])
    i += 1
  }
  @utf8.decode_lossy(Bytes::from_array(out[:]))
}

///|
fn parse_octal(text : String) -> Int32? {
  if text.length() == 0 || text.length() > 6 {
    return None
  }
  let mut value = 0
  for c in text {
    match digit_value(c) {
      Some(d) => value = value * 8 + d
      None => return None
    }
  }
  Some(value)
}

///|
fn parse_decimal(text : String) -> Int64? {
  if text.length() == 0 || text.length() > 15 {
    return None
  }
  let mut value = 0L
  for c in text {
    guard c is ('0'..<='9') else { return None }
    value = value * 10L + (c.to_int() - 48).to_int64()
  }
  Some(value)
}

///|
/// Parse `.MTREE` text: `/set` and `/unset` lines set defaults, every other
/// line is `path keyword=value ...`. Keywords this package does not use
/// (`time`, `uid`, `gid`, ...) are ignored.
pub fn parse_mtree(text : String) -> Array[MtreeEntry] raise ArchError {
  let defaults : Map[String, String] = Map([])
  let entries : Array[MtreeEntry] = []
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let parts = line.split(" ").filter(p => p.length() > 0).collect()
    if line.has_prefix("/") && !line.has_prefix("/ ") {
      let command = parts[0].to_owned()
      if command == "/set" {
        for i in 1..<parts.length() {
          match parts[i].find("=") {
            Some(at) =>
              defaults[parts[i][0:at].to_owned()] = parts[i][at + 1:].to_owned()
            None => ()
          }
        }
      } else if command == "/unset" {
        for i in 1..<parts.length() {
          defaults.remove(parts[i].to_owned())
        }
      } else {
        raise ArchError::Corrupt(
          message=".MTREE: unknown command \"\{command}\"",
        )
      }
      continue
    }
    let values : Map[String, String] = Map([])
    for pair in defaults {
      values[pair.0] = pair.1
    }
    for i in 1..<parts.length() {
      match parts[i].find("=") {
        Some(at) =>
          values[parts[i][0:at].to_owned()] = parts[i][at + 1:].to_owned()
        None => ()
      }
    }
    let path = clean_path(mtree_unquote(parts[0].to_owned()))
    if path == "" || path == "." || path == ".." {
      continue
    }
    let kind = match values.get("type") {
      Some(t) => t
      None => "file"
    }
    if kind != "file" && kind != "dir" && kind != "link" {
      raise ArchError::Corrupt(
        message=".MTREE: \"\{path}\" has the unsupported type \"\{kind}\"",
      )
    }
    let mode = match values.get("mode") {
      Some(m) =>
        match parse_octal(m) {
          Some(v) => Some(v)
          None => raise ArchError::Corrupt(message=".MTREE: bad mode \"\{m}\"")
        }
      None => None
    }
    let size = match values.get("size") {
      Some(s) =>
        match parse_decimal(s) {
          Some(v) => Some(v)
          None => raise ArchError::Corrupt(message=".MTREE: bad size \"\{s}\"")
        }
      None => None
    }
    entries.push({
      path,
      kind,
      mode,
      size,
      sha256: values.get("sha256digest").map(v => v.to_lower()),
      link: values.get("link").map(mtree_unquote),
    })
  }
  entries
}

///|
/// Open an Arch Linux package: unpack it (zstd, xz, gzip, lzma or plain tar,
/// found by the signature of the data), read the tar entries, `.PKGINFO`,
/// `.MTREE` and `.INSTALL`. `max_unpacked` bounds the unpacked size.
pub fn read(
  data : BytesView,
  max_unpacked~ : Int32 = 1073741824,
) -> ArchPackage raise ArchError {
  let compression = @compress.detect(data)
  let tar = @compress.decompress(data, compression, max_size=max_unpacked) catch {
    Corrupt(message) => raise ArchError::Corrupt(message~)
    TooLarge(_) =>
      raise ArchError::Corrupt(
        message="the package unpacks to more than \{max_unpacked} bytes",
      )
    Unsupported(message) => raise ArchError::Unsupported(message~)
  }
  let entries = @tar.parse(tar) catch {
    @tar.TarError::Unsupported(message~) =>
      raise ArchError::Unsupported(message~)
    err => raise ArchError::Corrupt(message="\{err}")
  }
  let mut info : String? = None
  let mut install : String? = None
  let mut mtree_text : String? = None
  for entry in entries {
    match (clean_path(entry.path), entry.kind) {
      (".PKGINFO", File(content)) => info = Some(@utf8.decode_lossy(content))
      (".INSTALL", File(content)) => install = Some(@utf8.decode_lossy(content))
      (".MTREE", File(content)) => {
        let text = @compress.decompress(content, Gzip, max_size=max_unpacked) catch {
          err => raise ArchError::Corrupt(message=".MTREE: \{err}")
        }
        mtree_text = Some(@utf8.decode_lossy(text))
      }
      _ => ()
    }
  }
  let pkginfo = match info {
    Some(text) => parse_pkginfo(text)
    None =>
      raise ArchError::Corrupt(
        message="there is no .PKGINFO, this is not an Arch Linux package",
      )
  }
  let mtree = match mtree_text {
    Some(text) => Some(parse_mtree(text))
    None => None
  }
  { compression: compression.name(), pkginfo, install, mtree, entries, }
}

///|
/// The first value of a `.PKGINFO` key.
pub fn ArchPackage::field(self : ArchPackage, key : String) -> String? {
  for pair in self.pkginfo {
    if pair.0 == key {
      return Some(pair.1)
    }
  }
  None
}

///|
/// All values of a `.PKGINFO` key, in file order.
pub fn ArchPackage::fields(self : ArchPackage, key : String) -> Array[String] {
  let result : Array[String] = []
  for pair in self.pkginfo {
    if pair.0 == key {
      result.push(pair.1)
    }
  }
  result
}

///|
fn has_dotdot(path : String) -> Bool {
  for segment in path.split("/") {
    if segment == ".." {
      return true
    }
  }
  false
}

///|
fn kind_of(entry : @tar.Entry) -> String {
  match entry.kind {
    File(_) => "file"
    Dir => "dir"
    Symlink(_) => "link"
    Hardlink(_) => "hardlink"
    Special(_) => "special"
  }
}

///|
/// How many checksums `verify` compares: the `.MTREE` entries with a SHA-256.
pub fn ArchPackage::checked_files(self : ArchPackage) -> Int32 {
  match self.mtree {
    None => 0
    Some(entries) => {
      let mut count = 0
      for e in entries {
        if e.sha256 is Some(_) {
          count += 1
        }
      }
      count
    }
  }
}

///|
/// Check the package against its own `.MTREE`: every listed path exists with
/// the same type, mode, size, SHA-256 and link target, and no file is missing
/// from the list. Also checks the `.PKGINFO` basics and the safety of the
/// paths. Returns the problems found; an empty array means it is sound.
pub fn ArchPackage::verify(self : ArchPackage) -> Array[String] {
  let problems : Array[String] = []
  for key in ["pkgname", "pkgver", "arch"] {
    if self.field(key) is None {
      problems.push(".PKGINFO: missing \{key}")
    }
  }
  let by_path : Map[String, @tar.Entry] = Map([])
  for entry in self.entries {
    let path = clean_path(entry.path)
    if path.has_prefix("/") || has_dotdot(path) {
      problems.push("\{entry.path}: unsafe path")
      continue
    }
    if by_path.contains(path) {
      problems.push("\{path}: appears twice in the archive")
    }
    by_path[path] = entry
  }
  match self.mtree {
    None => ()
    Some(listed) => {
      let seen : Map[String, Bool] = Map([])
      for item in listed {
        seen[item.path] = true
        match by_path.get(item.path) {
          None =>
            problems.push(
              "\{item.path}: listed in .MTREE but not in the package",
            )
          Some(entry) => {
            let kind = kind_of(entry)
            if kind != item.kind {
              problems.push(
                "\{item.path}: .MTREE says \{item.kind}, the package has a \{kind}",
              )
              continue
            }
            match item.mode {
              Some(mode) =>
                if (entry.mode & 0o7777) != mode {
                  problems.push(
                    "\{item.path}: mode \{(entry.mode & 0o7777).to_string(radix=8)} in the package, \{mode.to_string(radix=8)} in .MTREE",
                  )
                }
              None => ()
            }
            match entry.kind {
              File(content) => {
                match item.size {
                  Some(size) =>
                    if size != content.length().to_int64() {
                      problems.push(
                        "\{item.path}: size \{content.length()} in the package, \{size} in .MTREE",
                      )
                    }
                  None => ()
                }
                match item.sha256 {
                  Some(expected) => {
                    let actual = sha256_hex(content)
                    if actual != expected {
                      problems.push(
                        "\{item.path}: sha256 mismatch (.MTREE says \{expected}, content is \{actual})",
                      )
                    }
                  }
                  None => ()
                }
              }
              Symlink(target) =>
                match item.link {
                  Some(expected) =>
                    if expected != target {
                      problems.push(
                        "\{item.path}: link target \{target} in the package, \{expected} in .MTREE",
                      )
                    }
                  None => ()
                }
              _ => ()
            }
          }
        }
      }
      for path, _ in by_path {
        if path != ".MTREE" && !seen.contains(path) {
          problems.push("\{path}: in the package but not listed in .MTREE")
        }
      }
    }
  }
  problems
}

///|
fn octal_mode(mode : Int32) -> String {
  let digits = (mode & 0o7777).to_string(radix=8)
  "0".repeat(4 - digits.length().min(4)) + digits
}

///|
fn file_json(entry : @tar.Entry) -> Json {
  let size = match entry.kind {
    File(content) => content.length()
    _ => 0
  }
  let link : Json = match entry.kind {
    Symlink(target) | Hardlink(target) => Json::string(target)
    _ => Json::null()
  }
  let kind = match entry.kind {
    File(_) => "file"
    Dir => "dir"
    Symlink(_) => "symlink"
    Hardlink(_) => "hardlink"
    Special(_) => "special"
  }
  Json::object({
    "path": Json::string("/" + clean_path(entry.path)),
    "type": Json::string(kind),
    "mode": Json::string(octal_mode(entry.mode)),
    "owner": Json::string(if entry.uname == "" { "root" } else { entry.uname }),
    "group": Json::string(if entry.gname == "" { "root" } else { entry.gname }),
    "size": Json::number(size.to_double()),
    "mtime": Json::number(entry.mtime.to_double()),
    "link": link,
  })
}

///|
/// The functions defined in `.INSTALL`, for example `post_install`.
fn install_functions(text : String) -> Array[String] {
  let found : Array[String] = []
  for line in text.split("\n") {
    let line = line.trim().to_owned()
    if line.has_suffix("() {") || line.has_suffix("(){") {
      let name = line[0:line.find("(").unwrap()].trim().to_owned()
      found.push(name)
    }
  }
  found
}

///|
fn strings_json(items : Array[String]) -> Json {
  Json::array(items.map(Json::string))
}

///|
fn optional_json(value : String?) -> Json {
  match value {
    Some(text) => Json::string(text)
    None => Json::null()
  }
}

///|
/// Describe the package as JSON, in the same shape as the deb and rpm
/// reports (`format`, `name`, `version`, ..., `files`, `scripts`,
/// `conffiles`, `compression`). Pacman has a single kind of weak dependency,
/// `optdepend`, which is reported as `suggests`.
pub fn ArchPackage::to_json(self : ArchPackage) -> Json {
  let version_text = match self.field("pkgver") {
    Some(text) => text
    None => ""
  }
  // pkgver is [epoch:]version-release.
  let mut epoch : Json = Json::null()
  let mut rest = version_text
  match rest.find(":") {
    Some(at) =>
      match parse_decimal(rest[0:at].to_owned()) {
        Some(n) => {
          epoch = Json::number(n.to_double())
          rest = rest[at + 1:].to_owned()
        }
        None => ()
      }
    None => ()
  }
  let (version, release) = match rest.rev_find("-") {
    Some(at) => (rest[0:at].to_owned(), Some(rest[at + 1:].to_owned()))
    None => (rest, None)
  }
  let files : Array[Json] = []
  for entry in self.entries {
    if !is_metadata(clean_path(entry.path)) {
      files.push(file_json(entry))
    }
  }
  let scripts : Array[String] = match self.install {
    Some(text) => install_functions(text)
    None => []
  }
  let size = match self.field("size") {
    Some(text) =>
      match parse_decimal(text) {
        Some(n) => Json::number(((n + 1023L) / 1024L).to_double())
        None => Json::null()
      }
    None => Json::null()
  }
  let description = match self.field("pkgdesc") {
    Some(text) => text
    None => ""
  }
  Json::object({
    "format": Json::string("arch"),
    "name": optional_json(self.field("pkgname")),
    "version": Json::string(version),
    "release": optional_json(release),
    "epoch": epoch,
    "architecture": optional_json(self.field("arch")),
    "summary": Json::string(description),
    "description": Json::string(description),
    "maintainer": optional_json(self.field("packager")),
    "homepage": optional_json(self.field("url")),
    "license": match self.fields("license") {
      [] => Json::null()
      items => Json::string(items.join(", "))
    },
    "installed_size_kib": size,
    "depends": strings_json(self.fields("depend")),
    "recommends": strings_json([]),
    "suggests": strings_json(self.fields("optdepend")),
    "conflicts": strings_json(self.fields("conflict")),
    "replaces": strings_json(self.fields("replaces")),
    "provides": strings_json(self.fields("provides")),
    "files": Json::array(files),
    "scripts": strings_json(scripts),
    "conffiles": strings_json(self.fields("backup").map(p => "/" + p)),
    "compression": Json::object({ "payload": Json::string(self.compression) }),
    "pkgbase": optional_json(self.field("pkgbase")),
    "builddate": optional_json(self.field("builddate")),
  })
}
