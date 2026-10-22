///|
/// An Alpine Linux package opened for inspection.
pub(all) struct ApkPackage {
  /// The names of the signature files (`.SIGN.RSA.<key>`), when signed.
  signatures : Array[String]
  /// `.PKGINFO` as `(key, value)` pairs in file order.
  pkginfo : Array[(String, String)]
  /// Scripts and other files of the control segment: `(name, content)`.
  control_files : Array[(String, Bytes)]
  /// The data segment entries, each with the PAX records that came with it.
  data : Array[(@tar.Entry, Array[(String, String)])]
  /// The data segment as stored (gzip), which `datahash` covers.
  data_packed : Bytes
  /// The control segment as stored (gzip), which the signature covers.
  control_packed : Bytes
  /// The signature files: `(name, content, mtime)`.
  signature_files : Array[(String, Bytes, Int64)]
} derive(Eq, Debug)

///|
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
fn parse_tar(
  name : String,
  data : Bytes,
) -> Array[(@tar.Entry, Array[(String, String)])] raise ApkError {
  @tar.parse_with_records(data) catch {
    @tar.TarError::Unsupported(message~) =>
      raise ApkError::Unsupported(message="\{name}: \{message}")
    err => raise ApkError::Corrupt(message="\{name}: \{err}")
  }
}

///|
/// Open an Alpine Linux package (format 2): split the gzip streams, read the
/// signature names, `.PKGINFO`, scripts and the data tar. `max_unpacked`
/// bounds the unpacked size of all three together.
pub fn read(
  data : BytesView,
  max_unpacked~ : Int32 = 1073741824,
) -> ApkPackage raise ApkError {
  let members = @compress.gzip_members(data, max_size=max_unpacked) catch {
    Corrupt(message) => raise ApkError::Corrupt(message~)
    TooLarge(_) =>
      raise ApkError::Corrupt(
        message="the package unpacks to more than \{max_unpacked} bytes",
      )
    Unsupported(message) => raise ApkError::Unsupported(message~)
  }
  if members.length() < 2 || members.length() > 3 {
    raise ApkError::Corrupt(
      message="expected a control and a data stream (and maybe a signature), found \{members.length()} gzip stream(s)",
    )
  }
  let signatures : Array[String] = []
  let signature_files : Array[(String, Bytes, Int64)] = []
  let mut next = 0
  if members.length() == 3 {
    for item in parse_tar("signature", members[0].1) {
      let name = clean_path(item.0.path)
      signatures.push(name)
      match item.0.kind {
        File(content) => signature_files.push((name, content, item.0.mtime))
        _ => ()
      }
    }
    next = 1
  }
  let control = parse_tar("control", members[next].1)
  let data_entries = parse_tar("data", members[next + 1].1)
  let mut info : String? = None
  let control_files : Array[(String, Bytes)] = []
  for item in control {
    match item.0.kind {
      File(content) => {
        let name = clean_path(item.0.path)
        if name == ".PKGINFO" {
          info = Some(@utf8.decode_lossy(content))
        } else {
          control_files.push((name, content))
        }
      }
      _ => ()
    }
  }
  let pkginfo = match info {
    Some(text) => parse_pkginfo(text)
    None =>
      raise ApkError::Corrupt(
        message="the control segment has no .PKGINFO, this is not an Alpine Linux package",
      )
  }
  {
    signatures,
    pkginfo,
    control_files,
    data: data_entries,
    data_packed: members[next + 1].0,
    control_packed: members[next].0,
    signature_files,
  }
}

///|
/// The first value of a `.PKGINFO` key.
pub fn ApkPackage::field(self : ApkPackage, key : String) -> String? {
  for pair in self.pkginfo {
    if pair.0 == key {
      return Some(pair.1)
    }
  }
  None
}

///|
/// All values of a `.PKGINFO` key, in file order.
pub fn ApkPackage::fields(self : ApkPackage, key : String) -> Array[String] {
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
const CHECKSUM_KEY : String = "APK-TOOLS.checksum.SHA1"

///|
/// How many checksums `verify` compares: `datahash` and the per-file SHA-1
/// records.
pub fn ApkPackage::checked_files(self : ApkPackage) -> Int32 {
  let mut count = if self.field("datahash") is Some(_) { 1 } else { 0 }
  for item in self.data {
    for record in item.1 {
      if record.0 == CHECKSUM_KEY {
        count += 1
      }
    }
  }
  count
}

///|
/// Check the package: `datahash` is the SHA-256 of the data stream, every
/// regular file and symbolic link has the SHA-1 its PAX record states, the paths are safe, and
/// `.PKGINFO` has a name, version and architecture. Returns the problems
/// found; an empty array means the package is sound. Signatures are not
/// checked (apk needs the key for that).
pub fn ApkPackage::verify(self : ApkPackage) -> Array[String] {
  let problems : Array[String] = []
  for key in ["pkgname", "pkgver", "arch"] {
    if self.field(key) is None {
      problems.push(".PKGINFO: missing \{key}")
    }
  }
  match self.field("datahash") {
    None => problems.push(".PKGINFO: missing datahash")
    Some(expected) => {
      let actual = sha256_hex(self.data_packed)
      if actual != expected.to_lower() {
        problems.push(
          "datahash mismatch (.PKGINFO says \{expected}, the data stream is \{actual})",
        )
      }
    }
  }
  let seen : Map[String, Bool] = Map([])
  for item in self.data {
    let entry = item.0
    let path = clean_path(entry.path)
    if path.has_prefix("/") || has_dotdot(path) {
      problems.push("\{entry.path}: unsafe path")
      continue
    }
    if seen.contains(path) {
      problems.push("\{path}: appears twice in the data stream")
    }
    seen[path] = true
    match entry.kind {
      File(content) =>
        for record in item.1 {
          if record.0 == CHECKSUM_KEY {
            let actual = sha1_hex(content)
            if actual != record.1.to_lower() {
              problems.push(
                "\{path}: sha1 mismatch (the package says \{record.1}, content is \{actual})",
              )
            }
          }
        }
      Symlink(target) =>
        for record in item.1 {
          if record.0 == CHECKSUM_KEY {
            let actual = sha1_hex(@utf8.encode(target))
            if actual != record.1.to_lower() {
              problems.push(
                "\{path}: sha1 mismatch (the package says \{record.1}, the link text is \{actual})",
              )
            }
          }
        }
      _ => ()
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
    "elf": match entry.kind {
      File(content) => @elf.summary(content[:])
      _ => Json::null()
    },
  })
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
/// Describe the package as JSON in the shape the deb, rpm and Arch Linux
/// reports share. Dependencies starting with `!` are reported as
/// `conflicts`. apk has no recommendations or suggestions.
pub fn ApkPackage::to_json(self : ApkPackage) -> Json {
  let version_text = match self.field("pkgver") {
    Some(text) => text
    None => ""
  }
  // pkgver is version-r<revision>.
  let (version, release) = match version_text.rev_find("-r") {
    Some(at) =>
      (version_text[0:at].to_owned(), Some(version_text[at + 2:].to_owned()))
    None => (version_text, None)
  }
  let depends : Array[String] = []
  let conflicts : Array[String] = []
  for dep in self.fields("depend") {
    if dep.has_prefix("!") {
      conflicts.push(dep[1:].to_owned())
    } else {
      depends.push(dep)
    }
  }
  let files : Array[Json] = []
  for item in self.data {
    files.push(file_json(item.0))
  }
  let scripts : Array[String] = []
  for file in self.control_files {
    if file.0.has_prefix(".") {
      scripts.push(file.0[1:].to_owned())
    }
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
    "format": Json::string("apk"),
    "name": optional_json(self.field("pkgname")),
    "version": Json::string(version),
    "release": optional_json(release),
    "epoch": Json::null(),
    "architecture": optional_json(self.field("arch")),
    "summary": Json::string(description),
    "description": Json::string(description),
    "maintainer": optional_json(
      match self.field("packager") {
        Some(p) => Some(p)
        None => self.field("maintainer")
      },
    ),
    "homepage": optional_json(self.field("url")),
    "license": optional_json(self.field("license")),
    "installed_size_kib": size,
    "depends": strings_json(depends),
    "recommends": strings_json([]),
    "suggests": strings_json([]),
    "conflicts": strings_json(conflicts),
    "replaces": strings_json(self.fields("replaces")),
    "provides": strings_json(self.fields("provides")),
    "files": Json::array(files),
    "scripts": strings_json(scripts),
    "conffiles": strings_json([]),
    "compression": Json::object({ "payload": Json::string("gzip") }),
    "signatures": strings_json(self.signatures),
    "origin": optional_json(self.field("origin")),
    "builddate": optional_json(self.field("builddate")),
  })
}
