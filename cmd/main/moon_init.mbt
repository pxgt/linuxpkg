///|
/// The top-level `key = "value"` lines of a `moon.mod` (the text format).
fn parse_moon_mod(text : String) -> Map[String, String] {
  let fields : Map[String, String] = Map([])
  for raw in text.split("\n") {
    let line = raw.trim().to_owned()
    if line.has_prefix("//") ||
      line.has_prefix("import") ||
      line.has_prefix("}") {
      continue
    }
    match line.find(" = \"") {
      Some(at) if line.has_suffix("\"") => {
        let key = line[0:at].to_owned()
        let value = line[at + 4:line.length() - 1].to_owned()
        if !fields.contains(key) && !key.contains(" ") && !key.contains("\"") {
          fields[key] = value.replace_all(old="\\\"", new="\"")
        }
      }
      _ => ()
    }
  }
  fields
}

///|
fn json_string(map : Map[String, Json], key : String) -> String? {
  match map.get(key) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
/// The fields of the module description in `dir`: `moon.mod`, or the older
/// `moon.mod.json`.
fn read_moon_module(dir : String) -> Map[String, String] raise CliError {
  let text_path = join_path(dir, "moon.mod")
  if @fs.path_exists(text_path) {
    return parse_moon_mod(@utf8.decode_lossy(read_bytes(text_path)[:]))
  }
  let json_path = join_path(dir, "moon.mod.json")
  if @fs.path_exists(json_path) {
    let parsed = @json.parse(@utf8.decode_lossy(read_bytes(json_path)[:])) catch {
      err => raise Failed("\{json_path}: \{err}")
    }
    let fields : Map[String, String] = Map([])
    if parsed is Object(map) {
      for
        key in [
          "name", "version", "license", "repository", "description", "readme",
        ] {
        if json_string(map, key) is Some(value) {
          fields[key] = value
        }
      }
    }
    return fields
  }
  raise Failed("no moon.mod or moon.mod.json in \"\{dir}\"")
}

///|
fn is_executable_package(dir : String) -> Bool {
  let text_path = join_path(dir, "moon.pkg")
  if @fs.path_exists(text_path) {
    let text = @utf8.decode_lossy(read_bytes(text_path)[:]) catch { _ => "" }
    return text.contains("\"executable\"")
  }
  let json_path = join_path(dir, "moon.pkg.json")
  if @fs.path_exists(json_path) {
    let text = @utf8.decode_lossy(read_bytes(json_path)[:]) catch { _ => "" }
    return text.contains("\"is-main\": true") ||
      text.contains("\"is-main\":true")
  }
  false
}

///|
fn skipped_directory(name : String) -> Bool {
  name.has_prefix(".") ||
  name == "_build" ||
  name == "target" ||
  name == "node_modules" ||
  name == "examples" ||
  name == "docs"
}

///|
/// Relative paths of the executable packages under `dir` (the root is `""`).
fn find_executables(
  root : String,
  relative : String,
  depth : Int32,
  found : Array[String],
) -> Unit raise CliError {
  let here = if relative == "" { root } else { join_path(root, relative) }
  if is_executable_package(here) {
    found.push(relative)
  }
  if depth >= 4 {
    return
  }
  let listing = @fs.read_dir(here) catch { _ => [] }
  let names = listing.to_owned()
  names.sort()
  for name in names {
    if skipped_directory(name) {
      continue
    }
    let child = if relative == "" { name } else { relative + "/" + name }
    let is_dir = @fs.is_dir(join_path(root, child)) catch { _ => false }
    if is_dir {
      find_executables(root, child, depth + 1, found)
    }
  }
}

///|
/// A Debian-style package name from a module name: the part after the
/// slash, in lower case, with underscores turned into dashes.
fn package_name_of(module_name : String) -> String {
  let last = match module_name.rev_find("/") {
    Some(at) => module_name[at + 1:].to_owned()
    None => module_name
  }
  last.to_lower().replace_all(old="_", new="-")
}

///|
fn json_text(text : String) -> String {
  Json::string(text).stringify()
}

///|
/// `linuxpkg init --moon [DIR]`: write `DIR/linuxpkg.json` for the MoonBit
/// project in `DIR`, packaging the native executable it builds
/// (`moon build --target native --release`).
fn init_moon(options : Options) -> Int32 raise CliError {
  let dir = match options.positional {
    [] => "."
    [path] => path
    _ => raise Usage("init --moon takes at most one directory")
  }
  let fields = read_moon_module(dir)
  let module_name = match fields.get("name") {
    Some(name) => name
    None => raise Failed("\"\{dir}\" has no module name in its moon.mod")
  }
  let found : Array[String] = []
  find_executables(dir, "", 0, found)
  if found.length() == 0 {
    raise Failed(
      "no executable package found in \"\{dir}\" (a moon.pkg with pkgtype(kind: \"executable\"))",
    )
  }
  let chosen = match options.value("bin") {
    Some(wanted) =>
      if found.contains(wanted) {
        wanted
      } else {
        raise Failed(
          "no executable package \"\{wanted}\" in \"\{dir}\"; found: \{found.join(", ")}",
        )
      }
    None =>
      if found.length() == 1 {
        found[0]
      } else {
        raise Failed(
          "several executable packages (\{found.join(", ")}); choose one with --bin",
        )
      }
  }
  let package_dir = match chosen.rev_find("/") {
    Some(at) => chosen[at + 1:].to_owned()
    None => chosen
  }
  let base = package_name_of(module_name)
  let name = match options.value("name") {
    Some(name) => name
    None => base
  }
  // The built file is named after the package directory; the installed name
  // is the project's, unless the package has a name of its own.
  let file_stem = if chosen == "" {
    match module_name.rev_find("/") {
      Some(at) => module_name[at + 1:].to_owned()
      None => module_name
    }
  } else {
    package_dir
  }
  let built = if chosen == "" {
    "_build/native/release/build/\{file_stem}.exe"
  } else {
    "_build/native/release/build/\{chosen}/\{file_stem}.exe"
  }
  let command = if chosen == "" ||
    package_dir == "main" ||
    options.value("name") is Some(_) {
    name
  } else {
    package_dir
  }
  let arch = match options.value("arch") {
    Some(arch) => arch
    None => "amd64"
  }
  let version = fields.get("version").unwrap_or("0.1.0")
  let description = fields.get("description").unwrap_or(name)
  let contents : Array[String] = [
    "    { \"src\": \{json_text(built)}, \"dst\": \{json_text("/usr/bin/" + command)}, \"mode\": \"0755\" }",
  ]
  if @fs.path_exists(join_path(dir, "README.md")) {
    contents.push(
      "    { \"src\": \"README.md\", \"dst\": \{json_text("/usr/share/doc/" + name + "/README.md")} }",
    )
  }
  if @fs.path_exists(join_path(dir, "LICENSE")) {
    contents.push(
      "    { \"src\": \"LICENSE\", \"dst\": \{json_text("/usr/share/doc/" + name + "/copyright")} }",
    )
  }
  let out = StringBuilder()
  out.write_string("{\n")
  out.write_string("  \"name\": \{json_text(name)},\n")
  out.write_string("  \"version\": \{json_text(version)},\n")
  out.write_string("  \"release\": \"1\",\n")
  out.write_string("  \"arch\": \{json_text(arch)},\n")
  out.write_string("  \"maintainer\": \"Your Name <you@example.org>\",\n")
  out.write_string("  \"description\": \{json_text(description)},\n")
  if fields.get("repository") is Some(url) {
    out.write_string("  \"homepage\": \{json_text(url)},\n")
  }
  if fields.get("license") is Some(license) {
    out.write_string("  \"license\": \{json_text(license)},\n")
  }
  out.write_string("  \"contents\": [\n")
  out.write_string(contents.join(",\n"))
  out.write_string("\n  ]\n}\n")
  let target = join_path(dir, "linuxpkg.json")
  if @fs.path_exists(target) && !options.flag("force") {
    raise Failed("\"\{target}\" already exists, use --force to overwrite it")
  }
  write_bytes(target, @utf8.encode(out.to_string()))
  println(
    "wrote \{target} for the executable package \"\{if chosen == "" { "." } else { chosen }}\"",
  )
  println("Set \"maintainer\" in it, then:")
  println("  moon build --target native --release")
  println("  linuxpkg build \{target} --out dist")
  0
}
