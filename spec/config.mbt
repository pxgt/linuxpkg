///|
/// What a `contents` item of the configuration describes.
pub(all) enum ContentKind {
  /// A regular file read from `src`.
  File
  /// A regular file read from `src` that is also a configuration file.
  ConfigFile
  /// An empty directory.
  Dir
  /// A symbolic link at `dst` pointing to `src`.
  Symlink
} derive(Eq, Debug)

///|
/// One item of `contents`. `src` is a file to read for files, and the link
/// target for symbolic links. Unset `mode`, `owner`, `group` and `mtime` take
/// the defaults of their kind.
pub(all) struct Content {
  src : String?
  dst : String
  kind : ContentKind
  mode : Int32?
  owner : String?
  group : String?
  mtime : Int64?
} derive(Eq, Debug)

///|
/// Script files named by the configuration.
pub(all) struct ScriptPaths {
  pre_install : String?
  post_install : String?
  pre_remove : String?
  post_remove : String?
} derive(Eq, Debug)

///|
/// Options that apply to one output format (`"deb"` or `"rpm"` in the
/// configuration).
pub(all) struct FormatOptions {
  /// Overrides the package-wide `compression` for this format.
  compression : @compress.Compression?
} derive(Eq, Debug)

///|
/// A parsed `linuxpkg.json`. It still refers to files by name; call
/// `Config::sources` to learn which ones to read and `Config::resolve` to turn
/// it into a `PackageSpec` once they are available.
pub(all) struct Config {
  name : String
  version : String
  release : String
  epoch : Int32
  arch : Arch
  maintainer : String
  description : String
  homepage : String?
  license : String?
  vendor : String?
  section : String
  priority : String
  depends : Array[Dependency]
  recommends : Array[Dependency]
  suggests : Array[Dependency]
  conflicts : Array[Dependency]
  replaces : Array[Dependency]
  provides : Array[Dependency]
  contents : Array[Content]
  scripts : ScriptPaths
  mtime : Int64?
  /// Compression of the payload of every format (`gzip` when unset).
  compression : @compress.Compression?
  deb : FormatOptions
  rpm : FormatOptions
  /// Settings of the Arch Linux package (`"pacman"` in the file; `"arch"` is
  /// the CPU architecture).
  pacman : FormatOptions
  /// Path of an OpenPGP private key (relative to the configuration file) to
  /// sign rpm and Arch Linux packages with; `build --sign-key` overrides it.
  sign_key : String?
  /// File name of the Alpine public key (`mykey.rsa.pub`) written into the
  /// signature of apk packages; `linuxpkg-<key id>.rsa.pub` when unset.
  apk_key_name : String?
} derive(Eq, Debug)

///|
/// The compression to use for the deb: the `deb` setting, else the
/// package-wide one, else gzip.
pub fn Config::deb_compression(self : Config) -> @compress.Compression {
  match (self.deb.compression, self.compression) {
    (Some(c), _) | (None, Some(c)) => c
    (None, None) => Gzip
  }
}

///|
/// The compression to use for an Arch Linux package: the `pacman` setting, else
/// the package-wide one, else zstd (what makepkg uses).
pub fn Config::arch_compression(self : Config) -> @compress.Compression {
  match (self.pacman.compression, self.compression) {
    (Some(c), _) | (None, Some(c)) => c
    (None, None) => Zstd
  }
}

///|
/// The compression to use for the rpm: the `rpm` setting, else the
/// package-wide one, else gzip.
pub fn Config::rpm_compression(self : Config) -> @compress.Compression {
  match (self.rpm.compression, self.compression) {
    (Some(c), _) | (None, Some(c)) => c
    (None, None) => Gzip
  }
}

///|
let top_level_keys : Array[String] = [
  "$schema", "name", "version", "release", "epoch", "arch", "maintainer", "description",
  "homepage", "license", "vendor", "section", "priority", "depends", "recommends",
  "suggests", "conflicts", "replaces", "provides", "mtime", "contents", "scripts",
  "compression", "deb", "rpm", "pacman", "sign_key", "apk_key_name",
]

///|
let format_keys : Array[String] = ["compression"]

///|
let content_keys : Array[String] = [
  "src", "dst", "type", "mode", "owner", "group", "mtime", "file_info",
]

///|
let file_info_keys : Array[String] = ["mode", "owner", "group", "mtime"]

///|
let script_keys : Array[String] = [
  "preinstall", "postinstall", "preremove", "postremove",
]

///|
fn object_of(json : Json, field : String) -> Map[String, Json] raise SpecError {
  match json {
    Object(map) => map
    _ => raise invalid(field, "must be an object")
  }
}

///|
fn check_keys(
  map : Map[String, Json],
  allowed : Array[String],
  prefix : String,
) -> Unit raise SpecError {
  for key, _ in map {
    if !allowed.contains(key) {
      let field = if prefix == "" { key } else { "\{prefix}.\{key}" }
      let known = allowed.filter(k => k != "$schema").join(", ")
      raise invalid(field, "unknown field, expected one of: \{known}")
    }
  }
}

///|
fn opt_string(
  map : Map[String, Json],
  key : String,
  field : String,
) -> String? raise SpecError {
  match map.get(key) {
    None | Some(Null) => None
    Some(String(text)) => Some(text)
    Some(_) => raise invalid(field, "must be a string")
  }
}

///|
fn req_string(
  map : Map[String, Json],
  key : String,
  field : String,
) -> String raise SpecError {
  match opt_string(map, key, field) {
    Some(text) => text
    None => raise invalid(field, "is required")
  }
}

///|
/// A whole non-negative number that fits in 53 bits, so a JSON double holds
/// it exactly.
fn opt_whole(
  map : Map[String, Json],
  key : String,
  field : String,
) -> Int64? raise SpecError {
  match map.get(key) {
    None | Some(Null) => None
    Some(Number(n, ..)) => {
      let value = n.to_int64()
      if value.to_double() != n {
        raise invalid(field, "must be a whole number")
      }
      if value < 0L || value > 9007199254740992L {
        raise invalid(field, "must be between 0 and 9007199254740992")
      }
      Some(value)
    }
    Some(_) => raise invalid(field, "must be a number")
  }
}

///|
fn relations(
  map : Map[String, Json],
  key : String,
) -> Array[Dependency] raise SpecError {
  match map.get(key) {
    None | Some(Null) => []
    Some(Array(items)) => {
      let result : Array[Dependency] = []
      for i, item in items {
        let field = "\{key}[\{i}]"
        match item {
          String(text) => result.push(Dependency::parse(text, field~))
          _ => raise invalid(field, "must be a string")
        }
      }
      result
    }
    Some(_) => raise invalid(key, "must be an array of strings")
  }
}

///|
/// Parse a permission string such as `"0755"` or `"644"`.
fn parse_mode(text : String, field : String) -> Int32 raise SpecError {
  if text.length() == 0 || text.length() > 5 {
    raise invalid(field, "must be an octal string such as \"0644\"")
  }
  let mut value = 0
  for c in text {
    guard c is ('0'..<='7') else {
      raise invalid(field, "must be an octal string such as \"0644\"")
    }
    value = value * 8 + (c.to_int() - '0'.to_int())
  }
  validate_mode(value, field~)
  value
}

///|
fn opt_mode(map : Map[String, Json], field : String) -> Int32? raise SpecError {
  match map.get("mode") {
    None | Some(Null) => None
    Some(String(text)) => Some(parse_mode(text, "\{field}.mode"))
    Some(Number(_, ..)) =>
      raise invalid(
        "\{field}.mode",
        "must be a string such as \"0755\" (JSON numbers cannot be octal)",
      )
    Some(_) => raise invalid("\{field}.mode", "must be a string")
  }
}

///|
fn parse_kind(text : String?, field : String) -> ContentKind raise SpecError {
  match text {
    None | Some("") | Some("file") => File
    Some("config") | Some("config|noreplace") => ConfigFile
    Some("dir") => Dir
    Some("symlink") => Symlink
    Some(other) =>
      raise invalid(
        "\{field}.type",
        "unknown type \"\{other}\", expected file, config, dir or symlink",
      )
  }
}

///|
fn parse_content(json : Json, index : Int32) -> Content raise SpecError {
  let field = "contents[\{index}]"
  let map = object_of(json, field)
  check_keys(map, content_keys, field)
  // nFPM keeps mode/owner/group/mtime in a nested "file_info" object; both
  // spellings are accepted, but not at the same time.
  let nested = match map.get("file_info") {
    None | Some(Null) => false
    Some(_) => true
  }
  let info = match map.get("file_info") {
    None | Some(Null) => map
    Some(block) => {
      for key in ["mode", "owner", "group", "mtime"] {
        if map.contains(key) {
          raise invalid(
            "\{field}.\{key}",
            "cannot be combined with file_info, put it inside file_info",
          )
        }
      }
      let inner = object_of(block, "\{field}.file_info")
      check_keys(inner, file_info_keys, "\{field}.file_info")
      inner
    }
  }
  let info_field = if nested { "\{field}.file_info" } else { field }
  let dst = req_string(map, "dst", "\{field}.dst")
  validate_install_path(dst, field="\{field}.dst")
  let kind = parse_kind(opt_string(map, "type", "\{field}.type"), field)
  let src = opt_string(map, "src", "\{field}.src")
  match kind {
    File | ConfigFile =>
      match src {
        None => raise invalid("\{field}.src", "is required for files")
        Some("") => raise invalid("\{field}.src", "must not be empty")
        Some(_) => ()
      }
    Dir =>
      if src is Some(_) {
        raise invalid("\{field}.src", "is not allowed for directories")
      }
    Symlink =>
      match src {
        None =>
          raise invalid("\{field}.src", "is required, it is the link target")
        Some(target) => validate_link_target(target, field="\{field}.src")
      }
  }
  let mode = opt_mode(info, info_field)
  if kind is Symlink && mode is Some(_) {
    raise invalid("\{info_field}.mode", "is not allowed for symbolic links")
  }
  let owner = opt_string(info, "owner", "\{info_field}.owner")
  let group = opt_string(info, "group", "\{info_field}.group")
  match owner {
    Some(name) => validate_account(name, field="\{info_field}.owner")
    None => ()
  }
  match group {
    Some(name) => validate_account(name, field="\{info_field}.group")
    None => ()
  }
  let mtime = opt_whole(info, "mtime", "\{info_field}.mtime")
  { src, dst, kind, mode, owner, group, mtime, }
}

///|
/// A compression name the user may ask for: `none`, `gzip`, `xz` or `zstd`.
fn opt_compression(
  map : Map[String, Json],
  field : String,
) -> @compress.Compression? raise SpecError {
  match opt_string(map, "compression", field) {
    None => None
    Some(text) =>
      match @compress.Compression::parse(text) {
        Some(c) => Some(c)
        None =>
          raise invalid(
            field,
            "unknown compression \"\{text}\", expected none, gzip, xz or zstd",
          )
      }
  }
}

///|
fn parse_format_options(
  json : Json?,
  field : String,
) -> FormatOptions raise SpecError {
  match json {
    None | Some(Null) => { compression: None, }
    Some(value) => {
      let map = object_of(value, field)
      check_keys(map, format_keys, field)
      { compression: opt_compression(map, "\{field}.compression"), }
    }
  }
}

///|
fn parse_scripts(json : Json?) -> ScriptPaths raise SpecError {
  match json {
    None | Some(Null) =>
      {
        pre_install: None,
        post_install: None,
        pre_remove: None,
        post_remove: None,
      }
    Some(value) => {
      let map = object_of(value, "scripts")
      check_keys(map, script_keys, "scripts")
      let pick = (key : String) => opt_string(map, key, "scripts.\{key}")
      {
        pre_install: pick("preinstall"),
        post_install: pick("postinstall"),
        pre_remove: pick("preremove"),
        post_remove: pick("postremove"),
      }
    }
  }
}

///|
/// Parse the text of a `linuxpkg.json`. Field names follow nFPM where they
/// overlap. Unknown fields are rejected so that typos do not go unnoticed;
/// the returned config is syntactically valid but still has to be resolved
/// (and thereby validated as a whole) with `Config::resolve`.
///
/// # Example
/// ```mbt check
/// test {
///   let config = @spec.Config::parse(
///     (
///       #|{"name": "hello", "version": "1.0", "arch": "amd64",
///       #| "maintainer": "Jane <jane@example.org>", "description": "Hi",
///       #| "contents": [{"src": "hello.sh", "dst": "/usr/bin/hello", "mode": "0755"}]}
///     ),
///   )
///   assert_eq(config.name, "hello")
///   assert_eq(config.contents[0].mode, Some(0o755))
/// }
/// ```
pub fn Config::parse(text : String) -> Config raise SpecError {
  let json = @json.parse(text) catch { err => raise invalid("json", "\{err}") }
  let map = object_of(json, "config")
  check_keys(map, top_level_keys, "")
  let name = req_string(map, "name", "name")
  let version = req_string(map, "version", "version")
  let release = match opt_string(map, "release", "release") {
    Some(text) => text
    None => "1"
  }
  let epoch = match opt_whole(map, "epoch", "epoch") {
    Some(value) =>
      if value > MAX_EPOCH.to_int64() {
        raise invalid("epoch", "must be between 0 and \{MAX_EPOCH}")
      } else {
        value.to_int()
      }
    None => 0
  }
  let arch = Arch::parse(req_string(map, "arch", "arch"))
  let maintainer = req_string(map, "maintainer", "maintainer")
  let description = req_string(map, "description", "description")
  let section = match opt_string(map, "section", "section") {
    Some(text) => text
    None => "misc"
  }
  let priority = match opt_string(map, "priority", "priority") {
    Some(text) => text
    None => "optional"
  }
  let contents : Array[Content] = []
  match map.get("contents") {
    None | Some(Null) => ()
    Some(Array(items)) =>
      for i, item in items {
        contents.push(parse_content(item, i))
      }
    Some(_) => raise invalid("contents", "must be an array")
  }
  {
    name,
    version,
    release,
    epoch,
    arch,
    maintainer,
    description,
    homepage: opt_string(map, "homepage", "homepage"),
    license: opt_string(map, "license", "license"),
    vendor: opt_string(map, "vendor", "vendor"),
    section,
    priority,
    depends: relations(map, "depends"),
    recommends: relations(map, "recommends"),
    suggests: relations(map, "suggests"),
    conflicts: relations(map, "conflicts"),
    replaces: relations(map, "replaces"),
    provides: relations(map, "provides"),
    contents,
    scripts: parse_scripts(map.get("scripts")),
    mtime: opt_whole(map, "mtime", "mtime"),
    compression: opt_compression(map, "compression"),
    deb: parse_format_options(map.get("deb"), "deb"),
    rpm: parse_format_options(map.get("rpm"), "rpm"),
    pacman: parse_format_options(map.get("pacman"), "pacman"),
    sign_key: opt_string(map, "sign_key", "sign_key"),
    apk_key_name: opt_string(map, "apk_key_name", "apk_key_name"),
  }
}
