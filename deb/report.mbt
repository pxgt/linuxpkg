///|
fn octal_mode(mode : Int32) -> String {
  let digits = mode.to_string(radix=8)
  "0".repeat(4 - digits.length().min(4)) + digits
}

///|
fn kind_name(kind : @tar.EntryKind) -> String {
  match kind {
    File(_) => "file"
    Dir => "dir"
    Symlink(_) => "symlink"
    Hardlink(_) => "hardlink"
    Special(_) => "special"
  }
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
  Json::object({
    "path": Json::string(normalize_path(entry.path)),
    "type": Json::string(kind_name(entry.kind)),
    "mode": Json::string(octal_mode(entry.mode)),
    "owner": Json::string(entry.uname),
    "group": Json::string(entry.gname),
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
/// Split a `Depends`-style value into its comma separated relations.
fn split_relations(value : String) -> Array[Json] {
  let result : Array[Json] = []
  for item in value.split(",") {
    let item = item.trim().to_owned()
    if item.length() > 0 {
      result.push(Json::string(item))
    }
  }
  result
}

///|
fn DebPackage::optional_field(self : DebPackage, name : String) -> Json {
  match self.field(name) {
    Some(value) => Json::string(value)
    None => Json::null()
  }
}

///|
/// Describe the package as JSON. The shape is shared with the rpm reader:
/// `format`, `name`, `version`, `architecture`, `summary`, `description`,
/// `maintainer`, `homepage`, `license`, relations, `files`, `scripts`,
/// `conffiles` and `compression`; deb specific data sits in `fields` (the raw
/// control file) and `md5sums`.
pub fn DebPackage::to_json(self : DebPackage) -> Json {
  let description = match self.field("Description") {
    Some(text) => text
    None => ""
  }
  let summary = match description.split("\n").next() {
    Some(line) => line.to_owned()
    None => ""
  }
  let fields : Map[String, Json] = Map([])
  for field in self.fields {
    fields[field.0] = Json::string(field.1)
  }
  let relation = (name : String) => {
    match self.field(name) {
      Some(value) => Json::array(split_relations(value))
      None => Json::array([])
    }
  }
  let scripts : Array[Json] = []
  for item in self.control_files {
    match item.0 {
      "preinst" | "postinst" | "prerm" | "postrm" =>
        scripts.push(Json::string(item.0))
      _ => ()
    }
  }
  scripts.sort_by((a, b) => {
    match (a, b) {
      (String(x), String(y)) => compare_bytes(@utf8.encode(x), @utf8.encode(y))
      _ => 0
    }
  })
  Json::object({
    "format": Json::string("deb"),
    "format_version": Json::string(self.format_version),
    "name": self.optional_field("Package"),
    "version": self.optional_field("Version"),
    "architecture": self.optional_field("Architecture"),
    "summary": Json::string(summary),
    "description": Json::string(description),
    "maintainer": self.optional_field("Maintainer"),
    "homepage": self.optional_field("Homepage"),
    "license": Json::null(),
    "section": self.optional_field("Section"),
    "priority": self.optional_field("Priority"),
    "installed_size_kib": self.installed_size_json(),
    "depends": relation("Depends"),
    "recommends": relation("Recommends"),
    "suggests": relation("Suggests"),
    "conflicts": relation("Conflicts"),
    "replaces": relation("Replaces"),
    "provides": relation("Provides"),
    "files": Json::array(self.files.map(file_json)),
    "scripts": Json::array(scripts),
    "conffiles": Json::array(self.conffiles.map(Json::string)),
    "compression": Json::object({
      "control": Json::string(self.control_compression),
      "data": Json::string(self.data_compression),
    }),
    "md5sums": Json::number(self.md5sums.length().to_double()),
    "fields": Json::object(fields),
  })
}

///|
/// A non-negative decimal number, or `None` when `text` is anything else.
fn parse_count(text : String) -> Int32? {
  if text.length() == 0 || text.length() > 9 {
    return None
  }
  let mut value = 0
  for c in text {
    guard c is ('0'..<='9') else { return None }
    value = value * 10 + (c.to_int() - '0'.to_int())
  }
  Some(value)
}

///|
fn DebPackage::installed_size_json(self : DebPackage) -> Json {
  match self.field("Installed-Size") {
    Some(text) =>
      match parse_count(text.trim().to_owned()) {
        Some(n) => Json::number(n.to_double())
        None => Json::string(text)
      }
    None => Json::null()
  }
}
