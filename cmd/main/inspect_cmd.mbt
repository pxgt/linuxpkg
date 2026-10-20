///|
fn field_text(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(String(text)) => text
    Some(Number(n, ..)) => n.to_int64().to_string()
    _ => ""
  }
}

///|
fn field_list(map : Map[String, Json], key : String) -> Array[String] {
  let result : Array[String] = []
  match map.get(key) {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(text) => result.push(text)
          _ => ()
        }
      }
    _ => ()
  }
  result
}

///|
/// `ls -l` style permission string, for example `-rwxr-xr-x`.
fn mode_string(kind : String, mode_text : String) -> String {
  let mut mode = 0
  for c in mode_text {
    mode = mode * 8 + (c.to_int() - '0'.to_int())
  }
  let type_char = match kind {
    "dir" => 'd'
    "symlink" => 'l'
    "hardlink" => 'h'
    "special" => '?'
    _ => '-'
  }
  let out = StringBuilder()
  out.write_char(type_char)
  let bits = [
    (0o400, 'r'),
    (0o200, 'w'),
    (0o100, 'x'),
    (0o040, 'r'),
    (0o020, 'w'),
    (0o010, 'x'),
    (0o004, 'r'),
    (0o002, 'w'),
    (0o001, 'x'),
  ]
  for i, bit in bits {
    let set = (mode & bit.0) != 0
    let special = match i {
      2 => (mode & 0o4000) != 0
      5 => (mode & 0o2000) != 0
      8 => (mode & 0o1000) != 0
      _ => false
    }
    let c = if special {
      if i == 8 {
        if set {
          't'
        } else {
          'T'
        }
      } else if set {
        's'
      } else {
        'S'
      }
    } else if set {
      bit.1
    } else {
      '-'
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
fn pad_left(text : String, width : Int32) -> String {
  if text.length() >= width {
    text
  } else {
    " ".repeat(width - text.length()) + text
  }
}

///|
/// Human readable rendering of a package report (see `DebPackage::to_json`).
fn render_report(report : Json) -> String raise CliError {
  guard report is Object(map) else {
    raise Failed("internal error: bad report")
  }
  let out = StringBuilder()
  let line = (label : String, value : String) => {
    if value != "" {
      out.write_string(
        "\{label}\{" ".repeat(15 - label.length().min(14))}\{value}\n",
      )
    }
  }
  line("Package:", field_text(map, "name"))
  line("Version:", field_text(map, "version"))
  line("Release:", field_text(map, "release"))
  line("Architecture:", field_text(map, "architecture"))
  line("Maintainer:", field_text(map, "maintainer"))
  line("Homepage:", field_text(map, "homepage"))
  line("License:", field_text(map, "license"))
  line("Vendor:", field_text(map, "vendor"))
  line("Section:", field_text(map, "section"))
  let size = field_text(map, "installed_size_kib")
  if size != "" {
    line("Installed size:", "\{size} KiB")
  }
  for
    relation in [
      ("Depends:", "depends"),
      ("Recommends:", "recommends"),
      ("Suggests:", "suggests"),
      ("Conflicts:", "conflicts"),
      ("Replaces:", "replaces"),
      ("Provides:", "provides"),
    ] {
    line(relation.0, field_list(map, relation.1).join(", "))
  }
  let description = field_text(map, "description")
  let lines = description.split("\n").to_array()
  for i, text in lines {
    let text = text.to_owned()
    if i == 0 {
      line("Description:", text)
    } else if text.length() == 0 {
      out.write_string("\n")
    } else {
      out.write_string("\{" ".repeat(15)}\{text}\n")
    }
  }
  let scripts = field_list(map, "scripts")
  if scripts.length() > 0 {
    line("Scripts:", scripts.join(", "))
  }
  let conffiles = field_list(map, "conffiles")
  if conffiles.length() > 0 {
    line("Config files:", conffiles.join(", "))
  }
  match map.get("compression") {
    Some(Object(compression)) =>
      if compression.contains("payload") {
        line("Compression:", "payload \{field_text(compression, "payload")}")
      } else {
        line(
          "Compression:",
          "control \{field_text(compression, "control")}, data \{field_text(compression, "data")}",
        )
      }
    _ => ()
  }
  match map.get("files") {
    Some(Array(files)) => {
      out.write_string("\nFiles (\{files.length()}):\n")
      for file in files {
        guard file is Object(entry) else { continue }
        let kind = field_text(entry, "type")
        let mode = mode_string(kind, field_text(entry, "mode"))
        let owner = "\{field_text(entry, "owner")}/\{field_text(entry, "group")}"
        let size = pad_left(field_text(entry, "size"), 9)
        let link = match field_text(entry, "link") {
          "" => ""
          target => " -> \{target}"
        }
        out.write_string(
          "  \{mode}  \{owner}  \{size}  \{field_text(entry, "path")}\{link}\n",
        )
      }
    }
    _ => ()
  }
  out.to_string()
}

///|
fn cmd_inspect(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(args, Map([]), { "--json": "json" })
  let path = match options.positional {
    [path] => path
    [] => raise Usage("inspect needs the path of a package file")
    _ => raise Usage("inspect takes exactly one package file")
  }
  let report = load_package(path).report(path)
  if options.flag("json") {
    println(report.stringify(indent=2))
  } else {
    println(render_report(report).trim_end().to_owned())
  }
  0
}
