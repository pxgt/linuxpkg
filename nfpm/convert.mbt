///|
/// The result of reading an nFPM configuration: a `linuxpkg.json` as a JSON
/// object, and things that were left out or changed, one sentence each.
pub(all) struct Converted {
  config : Json
  warnings : Array[String]
}

///|
priv struct Ctx {
  host : Host
  warnings : Array[String]
  /// `deb`, `rpm`, `apk`, `archlinux`, or "" for no packager in particular.
  format : String
}

///|
fn Ctx::warn(self : Ctx, message : String) -> Unit {
  if !self.warnings.contains(message) {
    self.warnings.push(message)
  }
}

///|
fn Ctx::wants(self : Ctx, format : String) -> Bool {
  self.format == "" || self.format == format
}

///|
fn number_text(n : Double) -> String {
  if n == n.floor() && n.abs() < 9007199254740992.0 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}

///|
fn as_object(value : Json, path : String) -> Map[String, Json] raise NfpmError {
  match value {
    Object(map) => map
    Null => Map([])
    _ => raise invalid(path, "must be a mapping")
  }
}

///|
/// A scalar as text: a string stays, a number is written as a whole number
/// when it is one; `null` is empty. Anything else is an error.
fn text_of(value : Json?, path : String) -> String raise NfpmError {
  match value {
    None | Some(Null) => ""
    Some(String(text)) => text
    Some(Number(n, ..)) => number_text(n)
    Some(True) => "true"
    Some(False) => "false"
    Some(_) => raise invalid(path, "must be a text")
  }
}

///|
fn list_of(value : Json?, path : String) -> Array[String] raise NfpmError {
  match value {
    None | Some(Null) => []
    Some(Array(items)) => {
      let result : Array[String] = []
      for i, item in items {
        result.push(text_of(Some(item), "\{path}[\{i}]"))
      }
      result
    }
    Some(_) => raise invalid(path, "must be a list")
  }
}

///|
fn bool_of(value : Json?, path : String) -> Bool raise NfpmError {
  match value {
    None | Some(Null) | Some(False) => false
    Some(True) => true
    Some(_) => raise invalid(path, "must be true or false")
  }
}

///|
/// mergo's notion of "not set": null, an empty text or list or mapping, zero,
/// false.
fn is_unset(value : Json) -> Bool {
  match value {
    Null | False => true
    String(text) => text == ""
    Number(n, ..) => n == 0.0
    Array(items) => items.length() == 0
    Object(map) => map.length() == 0
    True => false
  }
}

///|
/// `over` laid on `base` like nFPM's `mergo.Merge(..., WithOverride)`:
/// mappings are merged key by key, any other value that is set replaces the
/// base value, unset values change nothing.
fn merge(base : Json, over : Json) -> Json {
  match (base, over) {
    (Object(b), Object(o)) => {
      let out : Map[String, Json] = Map([])
      for key, value in b {
        out[key] = value
      }
      for key, value in o {
        match out.get(key) {
          Some(existing) => out[key] = merge(existing, value)
          None => if !is_unset(value) { out[key] = value }
        }
      }
      Json::object(out)
    }
    _ => if is_unset(over) { base } else { over }
  }
}

///|
let info_keys : Array[String] = [
  "name", "arch", "platform", "epoch", "version", "version_schema", "release", "prerelease",
  "version_metadata", "section", "priority", "maintainer", "description", "vendor",
  "homepage", "license", "changelog", "disable_globbing", "mtime",
]

///|
let overridable_keys : Array[String] = [
  "replaces", "provides", "depends", "recommends", "suggests", "conflicts", "contents",
  "umask", "scripts", "rpm", "deb", "apk", "archlinux", "ipk", "msix",
]

///|
let content_keys : Array[String] = [
  "src", "dst", "type", "packager", "file_info", "expand", "disown_subtree",
]

///|
let file_info_keys : Array[String] = ["owner", "group", "mode", "mtime", "lang"]

///|
let scripts_keys : Array[String] = [
  "preinstall", "postinstall", "preremove", "postremove",
]

///|
let signature_keys : Array[String] = [
  "key_file", "key_id", "key_name", "method", "type", "signer",
]

///|
/// The known keys of every section, so that a typo is an error like in nFPM
/// (`KnownFields(true)`).
fn section_keys(name : String) -> Array[String]? {
  match name {
    "rpm" =>
      Some([
        "arch", "buildhost", "scripts", "requires", "group", "summary", "compression",
        "signature", "packager", "prefixes",
      ])
    "deb" =>
      Some([
        "arch", "arch_variant", "scripts", "triggers", "breaks", "signature", "compression",
        "fields", "predepends",
      ])
    "apk" => Some(["arch", "signature", "scripts"])
    "archlinux" => Some(["pkgbase", "arch", "packager", "scripts"])
    _ => None
  }
}

///|
/// The keys of the nested mappings of a packager section.
fn nested_keys(section : String) -> Array[(String, Array[String])] {
  match section {
    "rpm" =>
      [("scripts", ["pretrans", "posttrans", "verify"]), ("requires", ["post"])]
    "deb" =>
      [
        ("scripts", ["rules", "templates", "config"]),
        (
          "triggers",
          [
            "interest", "interest_await", "interest_noawait", "activate", "activate_await",
            "activate_noawait",
          ],
        ),
      ]
    "apk" => [("scripts", ["preupgrade", "postupgrade"])]
    "archlinux" => [("scripts", ["preupgrade", "postupgrade"])]
    _ => []
  }
}

///|
fn check_keys(
  map : Map[String, Json],
  allowed : Array[String],
  path : String,
) -> Unit raise NfpmError {
  for key, _ in map {
    if !allowed.contains(key) {
      raise invalid(
        if path == "" {
          key
        } else {
          "\{path}.\{key}"
        },
        "unknown field",
      )
    }
  }
}

///|
/// Check every key of the document against the schema of nFPM v2.
fn validate_document(root : Map[String, Json]) -> Unit raise NfpmError {
  let top : Array[String] = []
  for k in info_keys {
    top.push(k)
  }
  for k in overridable_keys {
    top.push(k)
  }
  top.push("overrides")
  check_keys(root, top, "")
  validate_overridable(root, "")
  match root.get("overrides") {
    Some(Object(overrides)) =>
      for format, value in overrides {
        let path = "overrides.\{format}"
        let map = as_object(value, path)
        check_keys(map, overridable_keys, path)
        validate_overridable(map, path)
      }
    None | Some(Null) => ()
    Some(_) => raise invalid("overrides", "must be a mapping")
  }
}

///|
fn validate_overridable(
  map : Map[String, Json],
  path : String,
) -> Unit raise NfpmError {
  let at = (key : String) => if path == "" { key } else { "\{path}.\{key}" }
  match map.get("contents") {
    Some(Array(items)) =>
      for i, item in items {
        let item_path = "\{at("contents")}[\{i}]"
        let content = as_object(item, item_path)
        check_keys(content, content_keys, item_path)
        match content.get("file_info") {
          Some(info) =>
            check_keys(
              as_object(info, "\{item_path}.file_info"),
              file_info_keys,
              "\{item_path}.file_info",
            )
          None => ()
        }
      }
    None | Some(Null) => ()
    Some(_) => raise invalid(at("contents"), "must be a list")
  }
  match map.get("scripts") {
    Some(scripts) =>
      check_keys(as_object(scripts, at("scripts")), scripts_keys, at("scripts"))
    None => ()
  }
  for name in ["rpm", "deb", "apk", "archlinux"] {
    match map.get(name) {
      Some(section) => {
        let section_path = at(name)
        let fields = as_object(section, section_path)
        check_keys(fields, section_keys(name).unwrap(), section_path)
        for pair in nested_keys(name) {
          let (sub, allowed) = pair
          match fields.get(sub) {
            Some(value) =>
              check_keys(
                as_object(value, "\{section_path}.\{sub}"),
                allowed,
                "\{section_path}.\{sub}",
              )
            None => ()
          }
        }
        match fields.get("signature") {
          Some(signature) =>
            check_keys(
              as_object(signature, "\{section_path}.signature"),
              signature_keys,
              "\{section_path}.signature",
            )
          None => ()
        }
      }
      None => ()
    }
  }
}

///|
fn rpm_group(merged : Map[String, Json]) -> Json? {
  match merged.get("rpm") {
    Some(Object(rpm)) => rpm.get("group")
    _ => None
  }
}

///|
/// The fields nFPM expands environment variables in, applied to a merged
/// configuration (nFPM expands before merging; the result is the same).
fn expand_document(
  root : Map[String, Json],
  host : Host,
) -> Unit raise NfpmError {
  let lookup = (name : String) => {
    match (host.getenv)(name) {
      Some(value) => value
      None => ""
    }
  }
  let expand_text = (map : Map[String, Json], key : String, path : String) => {
    match map.get(key) {
      Some(String(text)) => map[key] = Json::string(expand(text, lookup))
      Some(Number(_, ..)) => ()
      _ => ()
    }
    ignore(path)
  }
  let expand_list = (map : Map[String, Json], key : String, path : String) => {
    match map.get(key) {
      Some(Array(items)) => {
        let result : Array[Json] = []
        for i, item in items {
          let text = expand(text_of(Some(item), "\{path}[\{i}]"), lookup)
            .trim()
            .to_owned()
          if text != "" {
            result.push(Json::string(text))
          }
        }
        map[key] = Json::array(result)
      }
      _ => ()
    }
  }
  for
    key in [
      "release", "version", "prerelease", "platform", "arch", "name", "homepage",
      "maintainer", "vendor", "description",
    ] {
    expand_text(root, key, key)
  }
  for
    key in [
      "conflicts", "depends", "replaces", "recommends", "provides", "suggests",
    ] {
    expand_list(root, key, key)
  }
  match root.get("rpm") {
    Some(Object(rpm)) => {
      match rpm.get("requires") {
        Some(Object(requires)) =>
          expand_list(requires, "post", "rpm.requires.post")
        _ => ()
      }
      expand_text(rpm, "packager", "rpm.packager")
    }
    _ => ()
  }
  match root.get("deb") {
    Some(Object(deb)) => {
      expand_list(deb, "predepends", "deb.predepends")
      match deb.get("fields") {
        Some(Object(fields)) =>
          for key, _ in fields {
            expand_text(fields, key, "deb.fields.\{key}")
          }
        _ => ()
      }
    }
    _ => ()
  }
  for name in ["deb", "rpm", "apk"] {
    match root.get(name) {
      Some(Object(section)) =>
        match section.get("signature") {
          Some(Object(signature)) => {
            expand_text(signature, "key_file", "\{name}.signature.key_file")
            expand_text(signature, "key_id", "\{name}.signature.key_id")
          }
          _ => ()
        }
      _ => ()
    }
  }
  match root.get("contents") {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(content) =>
            if bool_of(content.get("expand"), "contents.expand") {
              for key in ["dst", "src"] {
                match content.get(key) {
                  Some(String(text)) =>
                    content[key] = Json::string(
                      expand(text, lookup).trim().to_owned(),
                    )
                  _ => ()
                }
              }
            }
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// The architecture in linuxpkg's spelling. nFPM's names (`386`, `arm5`,
/// `arm6`, `arm7`, `s390`, ...) are translated; everything else is passed on
/// and checked by the configuration reader.
fn map_arch(arch : String) -> String {
  match arch {
    "" => "amd64"
    "386" => "i386"
    "arm5" => "armel"
    "arm6" | "arm7" => "armhf"
    "s390" => "s390x"
    other => other
  }
}

///|
/// Normalize an octal mode written as `0755`, `755`, `0o755` or `04755` to a
/// string of at most four octal digits.
fn mode_text(text : String, path : String) -> String raise NfpmError {
  let digits = if text.has_prefix("0o") || text.has_prefix("0O") {
    text[2:].to_owned()
  } else {
    text
  }
  if digits.length() == 0 || digits.length() > 5 {
    raise invalid(path, "mode must be octal, for example 0755")
  }
  for c in digits {
    if c < '0' || c > '7' {
      raise invalid(
        path, "mode must be octal, for example 0755 (hexadecimal and decimal modes are not supported)",
      )
    }
  }
  let mut start = 0
  while start < digits.length() - 1 && digits[start] == '0' {
    start += 1
  }
  let trimmed = digits[start:].to_owned()
  "0".repeat(if trimmed.length() < 4 { 4 - trimmed.length() } else { 0 }) +
  trimmed
}

///|
fn digits_value(s : String) -> Int64? {
  if s.length() == 0 || s.length() > 9 {
    return None
  }
  let mut v = 0L
  for c in s {
    if !is_digit_char(c) {
      return None
    }
    v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(v)
}

///|
/// Days since 1970-01-01 of a calendar date (Howard Hinnant's algorithm).
fn days_from_civil(year : Int64, month : Int64, day : Int64) -> Int64 {
  let y = if month <= 2L { year - 1L } else { year }
  let era = (if y >= 0L { y } else { y - 399L }) / 400L
  let yoe = y - era * 400L
  let mp = (month + 9L) % 12L
  let doy = (153L * mp + 2L) / 5L + day - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
/// Seconds since the Unix epoch of `2006-01-02`, `2006-01-02T15:04:05Z`,
/// `2006-01-02 15:04:05` or with an offset (`+02:00`); the YAML timestamps
/// nFPM accepts for `mtime`.
fn parse_timestamp(text : String) -> Int64? {
  if text.length() < 10 || text[4] != '-' || text[7] != '-' {
    return None
  }
  guard digits_value(text[0:4].to_owned()) is Some(year) else { return None }
  guard digits_value(text[5:7].to_owned()) is Some(month) else { return None }
  guard digits_value(text[8:10].to_owned()) is Some(day) else { return None }
  if month < 1L || month > 12L || day < 1L || day > 31L {
    return None
  }
  let mut seconds = 0L
  let mut offset = 0L
  if text.length() > 10 {
    if text[10] != 'T' && text[10] != ' ' && text[10] != 't' {
      return None
    }
    if text.length() < 19 || text[13] != ':' || text[16] != ':' {
      return None
    }
    guard digits_value(text[11:13].to_owned()) is Some(hour) else {
      return None
    }
    guard digits_value(text[14:16].to_owned()) is Some(minute) else {
      return None
    }
    guard digits_value(text[17:19].to_owned()) is Some(second) else {
      return None
    }
    if hour > 23L || minute > 59L || second > 60L {
      return None
    }
    seconds = hour * 3600L + minute * 60L + second
    let mut at = 19
    if at < text.length() && text[at] == '.' {
      at += 1
      while at < text.length() && is_digit_char(text[at].unsafe_to_char()) {
        at += 1
      }
    }
    while at < text.length() && text[at] == ' ' {
      at += 1
    }
    if at < text.length() {
      if text[at] == 'Z' || text[at] == 'z' {
        at += 1
      } else if text[at] == '+' || text[at] == '-' {
        let sign = if text[at] == '-' { -1L } else { 1L }
        let parts = text[at + 1:]
          .to_owned()
          .split(":")
          .map(p => p.to_owned())
          .collect()
        guard digits_value(parts[0]) is Some(oh) else { return None }
        let om = if parts.length() > 1 {
          digits_value(parts[1])
        } else {
          Some(0L)
        }
        guard om is Some(minutes) else { return None }
        offset = sign * (oh * 3600L + minutes * 60L)
        at = text.length()
      }
      if at != text.length() {
        return None
      }
    }
  }
  Some(days_from_civil(year, month, day) * 86400L + seconds - offset)
}

///|
fn mtime_of(value : Json?, path : String) -> Int64? raise NfpmError {
  match value {
    None | Some(Null) => None
    Some(String(text)) =>
      match parse_timestamp(text) {
        Some(t) => Some(t)
        None =>
          raise invalid(
            path,
            "\"\{text}\" is not a time like 2024-01-31T12:00:00Z",
          )
      }
    Some(_) => raise invalid(path, "must be a time like 2024-01-31T12:00:00Z")
  }
}

///|
/// Warn about every field of `map` listed in `keys` that is set.
fn warn_unsupported(
  ctx : Ctx,
  map : Map[String, Json],
  keys : Array[String],
  path : String,
  why : String,
) -> Unit {
  for key in keys {
    match map.get(key) {
      Some(value) => if !is_unset(value) { ctx.warn("\{path}.\{key}: \{why}") }
      None => ()
    }
  }
}

///|
/// `/usr/share/x/` is `/usr/share/x`; the root stays.
fn strip_slashes(path : String) -> String {
  let mut end = path.length()
  while end > 1 && path[end - 1] == '/' {
    end -= 1
  }
  path[0:end].to_owned()
}

///|
/// A relation such as `libc6 (>= 2.31)`; alternatives (`a | b`, `(a or b)`)
/// have no equivalent in linuxpkg and are refused with a clear message.
fn check_relation(text : String, path : String) -> Unit raise NfpmError {
  if text.contains("|") || text.has_prefix("(") || text.contains(" or ") {
    raise invalid(
      path,
      "\"\{text}\" is an alternative or a rich dependency, which linuxpkg does not support; write one entry per package",
    )
  }
  if text.contains(",") {
    raise invalid(
      path,
      "\"\{text}\" lists several packages, write one entry per package",
    )
  }
}

///|
fn convert_contents(
  ctx : Ctx,
  items : Array[Json],
  disable_globbing : Bool,
) -> Array[Json] raise NfpmError {
  let result : Array[Json] = []
  for i, item in items {
    let path = "contents[\{i}]"
    let content = as_object(item, path)
    let packager = text_of(content.get("packager"), "\{path}.packager")
    if packager != "" {
      if ctx.format == "" {
        ctx.warn(
          "\{path}: only for \{packager}, left out (use --format \{packager})",
        )
        continue
      }
      if packager != ctx.format {
        continue
      }
    }
    let kind = text_of(content.get("type"), "\{path}.type")
    let source = text_of(content.get("src"), "\{path}.src")
    let raw_destination = text_of(content.get("dst"), "\{path}.dst")
    let destination = strip_slashes(raw_destination)
    if destination == "" {
      raise invalid("\{path}.dst", "is required")
    }
    let info = as_object(
      match content.get("file_info") {
        Some(j) => j
        None => Json::null()
      },
      "\{path}.file_info",
    )
    let owner = text_of(info.get("owner"), "\{path}.file_info.owner")
    let group = text_of(info.get("group"), "\{path}.file_info.group")
    let mode = match text_of(info.get("mode"), "\{path}.file_info.mode") {
      "" => ""
      text => mode_text(text, "\{path}.file_info.mode")
    }
    let mtime = mtime_of(info.get("mtime"), "\{path}.file_info.mtime")
    if text_of(info.get("lang"), "") != "" {
      ctx.warn(
        "\{path}.file_info.lang: language tags are not supported, left out",
      )
    }
    if !is_unset(
        match content.get("disown_subtree") {
          Some(j) => j
          None => Json::null()
        },
      ) {
      ctx.warn("\{path}.disown_subtree: not supported, left out")
    }
    // One output item for a file, with the common attributes.
    let make = (
      src : String?,
      dst : String,
      type_name : String,
      default_mode : String,
    ) => {
      let out : Map[String, Json] = Map([])
      match src {
        Some(s) => out["src"] = Json::string(s)
        None => ()
      }
      out["dst"] = Json::string(dst)
      if type_name != "" {
        out["type"] = Json::string(type_name)
      }
      let chosen = if mode != "" { mode } else { default_mode }
      if chosen != "" {
        out["mode"] = Json::string(chosen)
      }
      if owner != "" {
        out["owner"] = Json::string(owner)
      }
      if group != "" {
        out["group"] = Json::string(group)
      }
      match mtime {
        Some(t) => out["mtime"] = Json::number(t.to_double())
        None => ()
      }
      Json::object(out)
    }
    // nFPM copies the mode of the source file; linuxpkg cannot ask the file
    // system for it, so programs and scripts get 0755 and the rest 0644.
    let guess_mode = (file : String) => {
      match (ctx.host.read_file)(file) {
        Some(data) =>
          if data.length() >= 2 && data[0] == b'#' && data[1] == b'!' {
            "0755"
          } else if @elf.is_elf(data[:]) {
            "0755"
          } else {
            ""
          }
        None => ""
      }
    }
    match kind {
      ""
      | "file"
      | "config"
      | "config|noreplace"
      | "config|missingok"
      | "doc"
      | "license"
      | "licence"
      | "readme" => {
        let is_rpm_flag = kind == "doc" ||
          kind == "license" ||
          kind == "licence" ||
          kind == "readme"
        if is_rpm_flag {
          if ctx.format != "" && ctx.format != "rpm" {
            // nFPM leaves these out of every other format.
            continue
          }
          ctx.warn(
            "\{path}: type \"\{kind}\" is an rpm file flag, the file is installed as a plain file",
          )
        }
        if kind == "config|missingok" {
          ctx.warn(
            "\{path}: \"missingok\" is not supported, the file is a plain configuration file",
          )
        }
        let out_type = if kind.has_prefix("config") { "config" } else { "" }
        if source == "" {
          raise invalid("\{path}.src", "is required for a file")
        }
        let is_directory = (ctx.host.list_dir)(clean_path(source)) is Some(_)
        if (has_glob_chars(source) && !disable_globbing) ||
          is_directory ||
          raw_destination.has_suffix("/") {
          for
            pair in glob_files(
              ctx.host,
              source,
              raw_destination,
              disable_globbing,
            ) {
            result.push(
              make(Some(pair.0), pair.1, out_type, guess_mode(pair.0)),
            )
          }
        } else {
          result.push(
            make(Some(source), destination, out_type, guess_mode(source)),
          )
        }
      }
      "dir" => {
        let out : Map[String, Json] = Map([])
        out["dst"] = Json::string(destination)
        out["type"] = Json::string("dir")
        if mode != "" {
          out["mode"] = Json::string(mode)
        }
        if owner != "" {
          out["owner"] = Json::string(owner)
        }
        if group != "" {
          out["group"] = Json::string(group)
        }
        match mtime {
          Some(t) => out["mtime"] = Json::number(t.to_double())
          None => ()
        }
        result.push(Json::object(out))
      }
      "symlink" => {
        if source == "" {
          raise invalid("\{path}.src", "is required for a symlink (the target)")
        }
        let out : Map[String, Json] = Map([])
        out["src"] = Json::string(source)
        out["dst"] = Json::string(destination)
        out["type"] = Json::string("symlink")
        result.push(Json::object(out))
      }
      "ghost" => ctx.warn("\{path}: ghost files are not supported, left out")
      "tree"
      | "config|tree"
      | "config|noreplace|tree"
      | "config|missingok|tree" => {
        if source == "" {
          raise invalid("\{path}.src", "is required for a tree")
        }
        if (ctx.host.list_dir)(clean_path(source)) is None {
          raise invalid(
            "\{path}.src",
            "\"\{source}\" is not a directory (or cannot be read here)",
          )
        }
        let out_type = if kind.has_prefix("config") { "config" } else { "" }
        if kind.contains("missingok") {
          ctx.warn(
            "\{path}: \"missingok\" is not supported, the files are plain configuration files",
          )
        }
        ctx.warn(
          "\{path}: symbolic links inside a tree are installed as copies of their targets",
        )
        for entry in tree_entries(ctx.host, source) {
          let (relative, is_dir) = entry
          let target = join(destination, relative)
          if is_dir {
            let out : Map[String, Json] = Map([])
            out["dst"] = Json::string(target)
            out["type"] = Json::string("dir")
            if owner != "" {
              out["owner"] = Json::string(owner)
            }
            if group != "" {
              out["group"] = Json::string(group)
            }
            result.push(Json::object(out))
          } else {
            let file = join(clean_path(source), relative)
            result.push(make(Some(file), target, out_type, guess_mode(file)))
          }
        }
      }
      other =>
        raise invalid("\{path}.type", "invalid content type \"\{other}\"")
    }
  }
  result
}

///|
/// Read an nFPM configuration (`nfpm.yaml`) and give the `linuxpkg.json` that
/// builds the same package.
///
/// `format` is `deb`, `rpm`, `apk` or `archlinux` (`arch` is accepted too):
/// the `overrides` of that packager are applied, contents meant for other
/// packagers are left out and only that packager's own settings are looked at.
/// Without a format the top-level settings are converted and a warning names
/// the overrides that were not applied.
///
/// Every field of nFPM that linuxpkg does not support is named in the warnings,
/// nothing is dropped silently; a field that does not exist is an error, as in
/// nFPM. Environment variables are expanded in the same fields and with the
/// same rules as in nFPM (`$VAR`, `${VAR}`).
pub fn convert(
  text : String,
  host : Host,
  format~ : String = "",
) -> Converted raise NfpmError {
  let format = if format == "arch" { "archlinux" } else { format }
  if format != "" &&
    format != "deb" &&
    format != "rpm" &&
    format != "apk" &&
    format != "archlinux" {
    raise Invalid(
      "unknown format \"\{format}\", expected deb, rpm, apk or archlinux",
    )
  }
  let ctx : Ctx = { host, warnings: [], format, }
  let parsed = @yaml.loads(quote_numbers(text)) catch {
    err => raise Invalid("not valid YAML: \{err}")
  }
  let root = match parsed {
    Object(map) => map
    Null => raise Invalid("the file is empty")
    _ => raise Invalid("the file must be a mapping")
  }
  validate_document(root)
  // The base settings, with the overrides of this packager on top.
  let base : Map[String, Json] = Map([])
  for key, value in root {
    if key != "overrides" {
      base[key] = value
    }
  }
  let overrides = as_object(
    match root.get("overrides") {
      Some(j) => j
      None => Json::null()
    },
    "overrides",
  )
  let merged = if format == "" {
    let names : Array[String] = []
    for name, value in overrides {
      if !is_unset(value) {
        names.push(name)
      }
    }
    if names.length() > 0 {
      ctx.warn(
        "overrides for \{names.join(", ")} are not applied (use --format to convert for one packager)",
      )
    }
    base
  } else {
    match overrides.get(format) {
      Some(over) =>
        match merge(Json::object(base), over) {
          Object(map) => map
          _ => base
        }
      None => base
    }
  }
  for name, _ in overrides {
    if name != "deb" && name != "rpm" && name != "apk" && name != "archlinux" {
      ctx.warn("overrides.\{name}: not a packager of linuxpkg, ignored")
    }
  }
  expand_document(merged, host)
  // --- Info ---
  let name = text_of(merged.get("name"), "name")
  if name == "" {
    raise invalid("name", "package name must be provided")
  }
  let platform = text_of(merged.get("platform"), "platform")
  if platform != "" && platform != "linux" {
    raise invalid(
      "platform",
      "\"\{platform}\" is not supported, linuxpkg builds Linux packages",
    )
  }
  let section_arch = match format {
    "" => ""
    f =>
      text_of(
        match merged.get(f) {
          Some(Object(section)) => section.get("arch")
          _ => None
        },
        "\{f}.arch",
      )
  }
  let arch = map_arch(
    if section_arch != "" {
      section_arch
    } else {
      text_of(merged.get("arch"), "arch")
    },
  )
  let schema = text_of(merged.get("version_schema"), "version_schema")
  let version_in = text_of(merged.get("version"), "version")
  if version_in == "" {
    raise invalid("version", "package version must be provided")
  }
  let (core, prerelease, metadata) = settle_version(
    version_in,
    text_of(merged.get("prerelease"), "prerelease"),
    text_of(merged.get("version_metadata"), "version_metadata"),
    schema,
  )
  let version = core +
    (if prerelease == "" {
      ""
    } else {
      "~" + prerelease.replace_all(old="-", new=".")
    }) +
    (if metadata == "" {
      ""
    } else {
      "+" + metadata.replace_all(old="-", new=".")
    })
  let out : Map[String, Json] = Map([])
  out["name"] = Json::string(name)
  out["version"] = Json::string(version)
  let release = text_of(merged.get("release"), "release")
  if release != "" {
    out["release"] = Json::string(release)
  }
  match text_of(merged.get("epoch"), "epoch") {
    "" => ()
    epoch => {
      let mut value = 0L
      for c in epoch {
        if !is_digit_char(c) {
          raise invalid("epoch", "must be a whole number")
        }
        value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
      }
      if ctx.format == "apk" {
        ctx.warn("epoch: apk packages have no epoch, left out")
      } else {
        out["epoch"] = Json::number(value.to_double())
      }
    }
  }
  out["arch"] = Json::string(arch)
  let maintainer = text_of(merged.get("maintainer"), "maintainer")
  if maintainer == "" {
    ctx.warn(
      "maintainer is empty; linuxpkg needs one, \"Unknown <unknown@example.invalid>\" is used",
    )
    out["maintainer"] = Json::string("Unknown <unknown@example.invalid>")
  } else {
    out["maintainer"] = Json::string(maintainer)
  }
  let description = text_of(merged.get("description"), "description")
  out["description"] = Json::string(
    if description == "" {
      "no description given"
    } else {
      description
    },
  )
  for key in ["homepage", "license", "vendor", "section", "priority"] {
    match text_of(merged.get(key), key) {
      "" => ()
      value => out[key] = Json::string(value)
    }
  } // The "Group" of an rpm is linuxpkg's "section".
  if ctx.format == "rpm" {
    match text_of(rpm_group(merged), "rpm.group") {
      "" => ()
      group => out["section"] = Json::string(group)
    }
  }
  for
    key in [
      "depends", "recommends", "suggests", "conflicts", "replaces", "provides",
    ] {
    let items = list_of(merged.get(key), key)
    for i, item in items {
      check_relation(item, "\{key}[\{i}]")
    }
    if items.length() > 0 {
      out[key] = Json::array(items.map(Json::string))
    }
  }
  match mtime_of(merged.get("mtime"), "mtime") {
    Some(t) => out["mtime"] = Json::number(t.to_double())
    None => ()
  }
  // --- fields that linuxpkg does not have ---
  if text_of(merged.get("changelog"), "changelog") != "" {
    ctx.warn("changelog: not supported, left out")
  }
  if text_of(merged.get("umask"), "umask") != "" {
    ctx.warn(
      "umask: not used; modes come from file_info.mode (or 0755 for programs and scripts, 0644 otherwise)",
    )
  }
  for other in ["ipk", "msix"] {
    match merged.get(other) {
      Some(value) =>
        if !is_unset(value) {
          ctx.warn(
            "\{other}: linuxpkg does not build this format, settings ignored",
          )
        }
      None => ()
    }
  }
  // --- per packager sections ---
  let section = (name : String) => {
    as_object(
      match merged.get(name) {
        Some(j) => j
        None => Json::null()
      },
      name,
    )
  }
  let rpm = section("rpm")
  let deb = section("deb")
  let apk = section("apk")
  let archlinux = section("archlinux")
  if ctx.wants("rpm") {
    warn_unsupported(
      ctx,
      rpm,
      ["buildhost", "summary", "packager", "prefixes"],
      "rpm",
      "not supported, left out",
    )
    warn_unsupported(
      ctx,
      as_object(
        match rpm.get("scripts") {
          Some(j) => j
          None => Json::null()
        },
        "rpm.scripts",
      ),
      ["pretrans", "posttrans", "verify"],
      "rpm.scripts",
      "not supported, left out",
    )
    warn_unsupported(
      ctx,
      as_object(
        match rpm.get("requires") {
          Some(j) => j
          None => Json::null()
        },
        "rpm.requires",
      ),
      ["post"],
      "rpm.requires",
      "not supported, left out",
    )
  }
  if ctx.wants("deb") {
    warn_unsupported(
      ctx,
      deb,
      ["arch_variant", "breaks", "fields", "predepends", "triggers"],
      "deb",
      "not supported, left out",
    )
    warn_unsupported(
      ctx,
      as_object(
        match deb.get("scripts") {
          Some(j) => j
          None => Json::null()
        },
        "deb.scripts",
      ),
      ["rules", "templates", "config"],
      "deb.scripts",
      "not supported, left out",
    )
  }
  if ctx.wants("apk") {
    warn_unsupported(
      ctx,
      as_object(
        match apk.get("scripts") {
          Some(j) => j
          None => Json::null()
        },
        "apk.scripts",
      ),
      ["preupgrade", "postupgrade"],
      "apk.scripts",
      "not supported, left out",
    )
  }
  if ctx.wants("archlinux") {
    warn_unsupported(
      ctx,
      archlinux,
      ["pkgbase", "packager"],
      "archlinux",
      "not supported, left out",
    )
    warn_unsupported(
      ctx,
      as_object(
        match archlinux.get("scripts") {
          Some(j) => j
          None => Json::null()
        },
        "archlinux.scripts",
      ),
      ["preupgrade", "postupgrade"],
      "archlinux.scripts",
      "not supported, left out",
    )
  }
  // Compression.
  let deb_options : Map[String, Json] = Map([])
  if ctx.wants("deb") {
    match text_of(deb.get("compression"), "deb.compression") {
      "" => ()
      value => deb_options["compression"] = Json::string(value)
    }
  }
  let rpm_options : Map[String, Json] = Map([])
  if ctx.wants("rpm") {
    match text_of(rpm.get("compression"), "rpm.compression") {
      "" => ()
      "lzma" =>
        raise invalid(
          "rpm.compression", "lzma is not supported for writing (use gzip, xz or zstd)",
        )
      value => rpm_options["compression"] = Json::string(value)
    }
  }
  if deb_options.length() > 0 {
    out["deb"] = Json::object(deb_options)
  }
  if rpm_options.length() > 0 {
    out["rpm"] = Json::object(rpm_options)
  }
  // Signing.
  let signature_of = (map : Map[String, Json], section : String) => {
    as_object(
      match map.get("signature") {
        Some(j) => j
        None => Json::null()
      },
      "\{section}.signature",
    )
  }
  let mut key_file = ""
  for pair in [("rpm", rpm), ("apk", apk), ("deb", deb)] {
    if !ctx.wants(pair.0) {
      continue
    }
    let signature = signature_of(pair.1, pair.0)
    let file = text_of(
      signature.get("key_file"),
      "\{pair.0}.signature.key_file",
    )
    if text_of(signature.get("key_id"), "") != "" {
      ctx.warn(
        "\{pair.0}.signature.key_id: not supported, the key file is used as it is",
      )
    }
    if file == "" {
      continue
    }
    if pair.0 == "deb" {
      ctx.warn(
        "deb.signature: deb packages are not signed individually (sign the repository with linuxpkg repo --sign-key)",
      )
      continue
    }
    if key_file == "" {
      key_file = file
    } else if key_file != file {
      ctx.warn(
        "\{pair.0}.signature.key_file: linuxpkg signs all packages with one key, \"\{key_file}\" is used",
      )
    }
  }
  if key_file != "" {
    out["sign_key"] = Json::string(key_file)
    match (host.getenv)("NFPM_PASSPHRASE") {
      Some(pass) =>
        if pass != "" {
          ctx.warn(
            "NFPM_PASSPHRASE: keys with a passphrase are not supported, the key file must be unencrypted",
          )
        }
      None => ()
    }
  }
  match
    text_of(signature_of(apk, "apk").get("key_name"), "apk.signature.key_name") {
    "" => ()
    key_name =>
      if ctx.wants("apk") {
        out["apk_key_name"] = Json::string(key_name)
      }
  }
  // --- scripts ---
  let scripts = as_object(
    match merged.get("scripts") {
      Some(j) => j
      None => Json::null()
    },
    "scripts",
  )
  let scripts_out : Map[String, Json] = Map([])
  for key in ["preinstall", "postinstall", "preremove", "postremove"] {
    match text_of(scripts.get(key), "scripts.\{key}") {
      "" => ()
      path => scripts_out[key] = Json::string(path)
    }
  }
  if scripts_out.length() > 0 {
    out["scripts"] = Json::object(scripts_out)
  }
  // --- contents ---
  let items = match merged.get("contents") {
    Some(Array(items)) => items
    _ => []
  }
  let disable_globbing = bool_of(
    merged.get("disable_globbing"),
    "disable_globbing",
  )
  let contents = convert_contents(ctx, items, disable_globbing)
  out["contents"] = Json::array(contents)
  { config: Json::object(out), warnings: ctx.warnings, }
}
