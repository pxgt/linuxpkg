///|
fn sense_symbol(flags : Int32) -> String {
  let less = (flags & SENSE_LESS) != 0
  let greater = (flags & SENSE_GREATER) != 0
  let equal = (flags & SENSE_EQUAL) != 0
  match (less, greater, equal) {
    (true, false, false) => "<"
    (true, false, true) => "<="
    (false, true, false) => ">"
    (false, true, true) => ">="
    (false, false, true) => "="
    _ => ""
  }
}

///|
/// The relations of one kind as `name`, `name = 1.0` or `name >= 2` strings.
/// Entries that are not real packages (`rpmlib(...)` features) are left out
/// when `hide_rpmlib` is set.
fn relations_of(
  h : Header,
  names_tag : Int32,
  flags_tag : Int32,
  versions_tag : Int32,
  hide_rpmlib~ : Bool,
) -> Array[Json] {
  let names = h.strings(names_tag)
  let flags = h.ints(flags_tag)
  let versions = h.strings(versions_tag)
  let result : Array[Json] = []
  for i, name in names {
    if hide_rpmlib && name.has_prefix("rpmlib(") {
      continue
    }
    let op = if i < flags.length() { sense_symbol(flags[i]) } else { "" }
    let version = if i < versions.length() { versions[i] } else { "" }
    if op == "" || version == "" {
      result.push(Json::string(name))
    } else {
      result.push(Json::string("\{name} \{op} \{version}"))
    }
  }
  result
}

///|
fn octal_perm(mode : Int32) -> String {
  let digits = (mode & 0o7777).to_string(radix=8)
  "0".repeat(4 - digits.length().min(4)) + digits
}

///|
fn kind_of(mode : Int32) -> String {
  match mode & 0o170000 {
    0o100000 => "file"
    0o040000 => "dir"
    0o120000 => "symlink"
    _ => "special"
  }
}

///|
/// What `@elf.summary` says about each ELF file of the payload, by install
/// path. Left empty when the payload is large or cannot be unpacked (for
/// example an unsupported compressor): the rest of the report does not need it.
fn RpmPackage::elf_summaries(self : RpmPackage) -> Map[String, Json] {
  let found : Map[String, Json] = Map([])
  if self.payload.length() > ELF_SCAN_LIMIT {
    return found
  }
  try self.payload_entries(max_unpacked=ELF_SCAN_LIMIT * 8) catch {
    _ => ()
  } noraise {
    entries =>
      for entry in entries {
        let json = @elf.summary(entry.data[:])
        if json != Json::null() {
          let path = if entry.path.has_prefix("./") {
            entry.path[1:].to_owned()
          } else {
            entry.path
          }
          found[path] = json
        }
      }
  }
  found
}

///|
/// Largest compressed payload (bytes) whose files `inspect` looks into for ELF
/// headers.
const ELF_SCAN_LIMIT : Int32 = 33554432

///|
fn text_or_null(text : String) -> Json {
  if text == "" {
    Json::null()
  } else {
    Json::string(text)
  }
}

///|
/// Describe the package as JSON in the shape shared with the deb reader (see
/// `DebPackage::to_json`). rpm specific data: `release`, `epoch`, the
/// `compression.payload` name and the `signature` tags found.
pub fn RpmPackage::to_json(self : RpmPackage) -> Json raise RpmError {
  let h = self.header
  let files = self.files()
  let epoch : Json = match h.ints(1003) {
    [e, ..] => Json::number(e.to_double())
    [] => Json::null()
  }
  let description = match h.strings(1005) {
    [text, ..] => text
    [] => ""
  }
  let summary = match h.strings(1004) {
    [text, ..] => text
    [] => ""
  }
  let conffiles : Array[Json] = []
  let file_json : Array[Json] = []
  let elf_files = self.elf_summaries()
  for file in files {
    if (file.flags & FILE_CONFIG) != 0 {
      conffiles.push(Json::string(file.path))
    }
    file_json.push(
      Json::object({
        "path": Json::string(file.path),
        "type": Json::string(kind_of(file.mode)),
        "mode": Json::string(octal_perm(file.mode)),
        "owner": Json::string(file.owner),
        "group": Json::string(file.group),
        "size": Json::number(file.size.to_double()),
        "mtime": Json::number(file.mtime.to_double()),
        "link": text_or_null(file.link),
        "elf": match elf_files.get(file.path) {
          Some(json) => json
          None => Json::null()
        },
      }),
    )
  }
  let scripts : Array[Json] = []
  for pair in [(1023, "pre"), (1024, "post"), (1025, "preun"), (1026, "postun")] {
    if h.get(pair.0) is Some(_) {
      scripts.push(Json::string(pair.1))
    }
  }
  let signature : Array[Json] = []
  for tag in self.signature.tags {
    let name = match tag.id {
      273 => "sha256"
      269 => "sha1"
      1000 => "size"
      1004 => "md5"
      1007 => "payloadsize"
      1008 => "reserved"
      270 => "longsize"
      271 => "longpayloadsize"
      268 => "rsa"
      267 => "dsa"
      1002 => "rsa-header"
      1003 => "dsa-header"
      1005 => "gpg"
      1006 => "pgp"
      _ => "tag-\{tag.id}"
    }
    signature.push(Json::string(name))
  }
  let release = h.text(1002)
  let version = h.text(1001)
  Json::object({
    "format": Json::string("rpm"),
    "name": text_or_null(h.text(1000)),
    "version": text_or_null(version),
    "release": text_or_null(release),
    "epoch": epoch,
    "architecture": text_or_null(h.text(1022)),
    "summary": Json::string(summary),
    "description": Json::string(description),
    "maintainer": text_or_null(h.text(1015)),
    "homepage": text_or_null(h.text(1020)),
    "license": text_or_null(h.text(1014)),
    "vendor": text_or_null(h.text(1011)),
    "section": text_or_null(
      match h.strings(1016) {
        [g, ..] => g
        [] => ""
      },
    ),
    "installed_size_kib": match h.numbers(5009) {
      [n, ..] => Json::number(((n + 1023L) / 1024L).to_double())
      [] =>
        match h.numbers(1009) {
          [n, ..] => Json::number(((n + 1023L) / 1024L).to_double())
          [] => Json::null()
        }
    },
    "depends": Json::array(relations_of(h, 1049, 1048, 1050, hide_rpmlib=true)),
    "recommends": Json::array(
      relations_of(h, 5046, 5048, 5047, hide_rpmlib=true),
    ),
    "suggests": Json::array(relations_of(h, 5049, 5051, 5050, hide_rpmlib=true)),
    "conflicts": Json::array(
      relations_of(h, 1054, 1053, 1055, hide_rpmlib=true),
    ),
    "replaces": Json::array(relations_of(h, 1090, 1114, 1115, hide_rpmlib=true)),
    "provides": Json::array(relations_of(h, 1047, 1112, 1113, hide_rpmlib=true)),
    "files": Json::array(file_json),
    "scripts": Json::array(scripts),
    "conffiles": Json::array(conffiles),
    "compression": Json::object({ "payload": Json::string(self.compressor()) }),
    "signature": Json::array(signature),
  })
}
