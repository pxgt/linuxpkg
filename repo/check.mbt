///|
fn find_file(files : Array[(String, Bytes)], name : String) -> Bytes? {
  for file in files {
    if file.0 == name {
      return Some(file.1)
    }
  }
  None
}

///|
/// The text between `open` and `close`, starting the search at `from`;
/// returns the text and the position after `close`.
fn between(
  text : String,
  open : String,
  close : String,
  from : Int32,
) -> (String, Int32)? {
  match text[from:].find(open) {
    None => None
    Some(a) => {
      let start = from + a + open.length()
      match text[start:].find(close) {
        None => None
        Some(b) =>
          Some((text[start:start + b].to_owned(), start + b + close.length()))
      }
    }
  }
}

///|
/// The value of `name="..."` inside one tag's text.
fn attribute(tag : String, name : String) -> String? {
  match between(tag, " \{name}=\"", "\"", 0) {
    Some((value, _)) => Some(value)
    None => None
  }
}

///|
fn unescape_xml(text : String) -> String {
  text
  .replace_all(old="&lt;", new="<")
  .replace_all(old="&gt;", new=">")
  .replace_all(old="&quot;", new="\"")
  .replace_all(old="&amp;", new="&")
}

///|
fn digest_by_name(name : String, data : Bytes) -> String? {
  match name {
    "MD5Sum" => Some(md5_hex(data))
    "SHA1" => Some(sha1_hex(data))
    "SHA256" => Some(sha256_hex(data))
    _ => None
  }
}

///|
/// Check the index files of a flat apt repository (as made by `apt_index`)
/// against each other and against the debs: the hashes and sizes in
/// `Release`, equal content of `Packages`, `Packages.gz` and `Packages.xz`,
/// and one correct stanza per deb. Returns the problems found; an empty
/// array means the repository is consistent.
pub fn check_apt(
  files : Array[(String, Bytes)],
  debs : Array[PackageFile],
) -> Array[String] {
  let problems : Array[String] = []
  let release = match find_file(files, "Release") {
    Some(data) => @utf8.decode_lossy(data)
    None => {
      problems.push("Release is missing")
      return problems
    }
  }
  // Release: `Field: value` lines, and ` hash size name` lines below the
  // hash sections.
  let mut section = ""
  let mut has_date = false
  for line in release.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("Date:") {
      has_date = true
    }
    if line.has_prefix(" ") {
      let parts = line.trim().split(" ").filter(p => p.length() > 0).collect()
      if parts.length() != 3 {
        problems.push("Release: malformed line \"\{line}\"")
        continue
      }
      match find_file(files, parts[2].to_owned()) {
        None => problems.push("Release lists \{parts[2]} which does not exist")
        Some(data) => {
          if parts[1].to_owned() != data.length().to_string() {
            problems.push(
              "Release: \{parts[2]} is \{data.length()} bytes, not \{parts[1]}",
            )
          }
          match digest_by_name(section, data) {
            Some(actual) =>
              if actual != parts[0].to_owned() {
                problems.push(
                  "Release: \{section} of \{parts[2]} does not match",
                )
              }
            None => ()
          }
        }
      }
    } else if line.has_suffix(":") {
      section = line[0:line.length() - 1].to_owned()
    }
  }
  if !has_date {
    problems.push("Release has no Date field")
  }
  for name in ["Packages", "Packages.gz", "Packages.xz"] {
    if !release.contains(" \{name}\n") {
      problems.push("Release does not list \{name}")
    }
  }
  let packages = match find_file(files, "Packages") {
    Some(data) => data
    None => {
      problems.push("Packages is missing")
      return problems
    }
  }
  for
    pair in [("Packages.gz", @compress.Compression::Gzip), ("Packages.xz", Xz)] {
    match find_file(files, pair.0) {
      None => problems.push("\{pair.0} is missing")
      Some(packed) =>
        try @compress.decompress(packed, pair.1) catch {
          err => problems.push("\{pair.0}: \{err}")
        } noraise {
          plain =>
            if plain != packages {
              problems.push("\{pair.0} does not unpack to Packages")
            }
        }
    }
  }
  // One stanza per deb, with the right file facts.
  let seen : Map[String, Bool] = Map([])
  for block in @utf8.decode_lossy(packages).split("\n\n") {
    let block = block.to_owned()
    if block.trim() == "" {
      continue
    }
    let fields = @deb.parse_control(block) catch {
      err => {
        problems.push("Packages: \{err}")
        continue
      }
    }
    let get = (key : String) => {
      for f in fields {
        if f.0 == key {
          return f.1
        }
      }
      ""
    }
    let filename = get("Filename")
    let name = if filename.has_prefix("./") {
      filename[2:].to_owned()
    } else {
      filename
    }
    seen[name] = true
    let mut found : PackageFile? = None
    for deb in debs {
      if deb.name == name {
        found = Some(deb)
      }
    }
    match found {
      None =>
        problems.push("Packages lists \{filename}, which is not a given deb")
      Some(deb) => {
        if get("Size") != deb.data.length().to_string() {
          problems.push(
            "\{name}: Size is \{get("Size")}, the file has \{deb.data.length()} bytes",
          )
        }
        if get("MD5sum") != md5_hex(deb.data) {
          problems.push("\{name}: MD5sum does not match")
        }
        if get("SHA1") != sha1_hex(deb.data) {
          problems.push("\{name}: SHA1 does not match")
        }
        if get("SHA256") != sha256_hex(deb.data) {
          problems.push("\{name}: SHA256 does not match")
        }
        try @deb.read(deb.data) catch {
          err => problems.push("\{name}: \{err}")
        } noraise {
          pkg =>
            for key in ["Package", "Version", "Architecture"] {
              if pkg.field(key) != Some(get(key)) {
                problems.push("\{name}: \{key} differs from the control file")
              }
            }
        }
      }
    }
  }
  for deb in debs {
    if !seen.contains(deb.name) {
      problems.push("Packages does not list \{deb.name}")
    }
  }
  problems
}

///|
/// Check the files of a dnf/yum repository (as made by `yum_index`):
/// every file `repomd.xml` refers to exists with the stated size, checksum
/// and unpacked checksum and size, and `primary.xml` / `filelists.xml` /
/// `other.xml` describe exactly the given rpms (checksum, size, location).
/// Returns the problems found.
pub fn check_yum(
  files : Array[(String, Bytes)],
  rpms : Array[PackageFile],
) -> Array[String] {
  let problems : Array[String] = []
  let repomd = match find_file(files, "repodata/repomd.xml") {
    Some(data) => @utf8.decode_lossy(data)
    None => {
      problems.push("repodata/repomd.xml is missing")
      return problems
    }
  }
  let documents : Map[String, String] = Map([])
  let mut position = 0
  while true {
    match between(repomd, "<data type=\"", "</data>", position) {
      None => break
      Some((block, next)) => {
        position = next
        let kind = match between(block, "", "\"", 0) {
          Some((k, _)) => k
          None => ""
        }
        let text = (open : String, close : String) => {
          match between(block, open, close, 0) {
            Some((value, _)) => value
            None => ""
          }
        }
        let checksum = text("<checksum type=\"sha256\">", "</checksum>")
        let open_checksum = text(
          "<open-checksum type=\"sha256\">", "</open-checksum>",
        )
        let location = match between(block, "<location href=\"", "\"", 0) {
          Some((value, _)) => value
          None => ""
        }
        match find_file(files, location) {
          None => problems.push("\{kind}: \{location} does not exist")
          Some(packed) => {
            if sha256_hex(packed) != checksum {
              problems.push("\{kind}: checksum does not match \{location}")
            }
            if text("<size>", "</size>") != packed.length().to_string() {
              problems.push("\{kind}: size does not match \{location}")
            }
            if !location.contains(checksum) {
              problems.push(
                "\{kind}: the file name does not contain the checksum",
              )
            }
            try @compress.decompress(packed, Gzip) catch {
              err => problems.push("\{kind}: \{err}")
            } noraise {
              plain => {
                if sha256_hex(plain) != open_checksum {
                  problems.push("\{kind}: open-checksum does not match")
                }
                if text("<open-size>", "</open-size>") !=
                  plain.length().to_string() {
                  problems.push("\{kind}: open-size does not match")
                }
                documents[kind] = @utf8.decode_lossy(plain)
              }
            }
          }
        }
      }
    }
  }
  for kind in ["primary", "filelists", "other"] {
    if !documents.contains(kind) {
      problems.push("repomd.xml has no \{kind} entry")
    }
  }
  match documents.get("primary") {
    None => ()
    Some(primary) => {
      let listed : Map[String, Bool] = Map([])
      let mut at = 0
      while true {
        match between(primary, "<package type=\"rpm\">", "</package>", at) {
          None => break
          Some((block, next)) => {
            at = next
            let pkgid = match
              between(block, "pkgid=\"YES\">", "</checksum>", 0) {
              Some((v, _)) => v
              None => ""
            }
            let href = match between(block, "<location href=\"", "\"", 0) {
              Some((v, _)) => unescape_xml(v)
              None => ""
            }
            listed[href] = true
            let mut found : PackageFile? = None
            for rpm in rpms {
              if rpm.name == href {
                found = Some(rpm)
              }
            }
            match found {
              None =>
                problems.push("primary lists \{href}, which is not a given rpm")
              Some(rpm) => {
                if pkgid != sha256_hex(rpm.data) {
                  problems.push("\{href}: pkgid does not match the file")
                }
                let size_tag = match between(block, "<size ", "/>", 0) {
                  Some((v, _)) => v
                  None => ""
                }
                if attribute(" " + size_tag, "package") !=
                  Some(rpm.data.length().to_string()) {
                  problems.push("\{href}: size package does not match the file")
                }
                let range = match
                  between(block, "<rpm:header-range ", "/>", 0) {
                  Some((v, _)) => v
                  None => ""
                }
                let start = attribute(" " + range, "start")
                let end = attribute(" " + range, "end")
                match (start, end) {
                  (Some(s), Some(e)) =>
                    try {
                      let pkg = @rpm.read(rpm.data)
                      let stop = rpm.data.length() - pkg.payload.length()
                      if e != stop.to_string() ||
                        s != (stop - pkg.header_bytes.length()).to_string() {
                        problems.push(
                          "\{href}: header-range does not match the rpm",
                        )
                      }
                    } catch {
                      err => problems.push("\{href}: \{err}")
                    }
                  _ => problems.push("\{href}: header-range is missing")
                }
              }
            }
          }
        }
      }
      for rpm in rpms {
        if !listed.contains(rpm.name) {
          problems.push("primary does not list \{rpm.name}")
        }
      }
      let declared = match between(primary, "packages=\"", "\"", 0) {
        Some((v, _)) => v
        None => ""
      }
      if declared != rpms.length().to_string() {
        problems.push(
          "primary says \{declared} packages, \{rpms.length()} were given",
        )
      }
    }
  }
  for kind in ["filelists", "other"] {
    match documents.get(kind) {
      None => ()
      Some(text) =>
        for rpm in rpms {
          if !text.contains("pkgid=\"\{sha256_hex(rpm.data)}\"") {
            problems.push("\{kind} does not describe \{rpm.name}")
          }
        }
    }
  }
  problems
}
