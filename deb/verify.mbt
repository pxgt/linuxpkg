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
/// Check the integrity of an opened deb and return one line per problem; an
/// empty array means the package is sound.
///
/// - the `control` file has the mandatory fields,
/// - every `md5sums` entry names a regular file of the package and matches
///   its content,
/// - every `conffiles` entry exists in the package,
/// - no path escapes the installation root (`..`) and none appears twice.
///
/// Gzip CRCs and archive structure were already checked by `read`.
pub fn DebPackage::verify(self : DebPackage) -> Array[String] {
  let problems : Array[String] = []
  for
    name in ["Package", "Version", "Architecture", "Maintainer", "Description"] {
    if self.field(name) is None {
      problems.push("control: missing required field \"\{name}\"")
    }
  }
  let regular : Map[String, Bytes] = Map([])
  let seen : Map[String, Bool] = Map([])
  for entry in self.files {
    let path = normalize_path(entry.path)
    if has_dotdot(entry.path) {
      problems.push("\{entry.path}: path escapes the installation root")
    }
    if path != "/" {
      if seen.contains(path) {
        problems.push("\{path}: appears more than once in data.tar")
      }
      seen[path] = true
    }
    match entry.kind {
      File(content) => regular[path] = content
      _ => ()
    }
  }
  for sum in self.md5sums {
    let (path, expected) = sum
    match regular.get(path) {
      None =>
        problems.push(
          "\{path}: listed in md5sums but is not a file of the package",
        )
      Some(content) => {
        let actual = md5_hex(content)
        if actual != expected {
          problems.push(
            "\{path}: md5 mismatch (md5sums says \{expected}, content is \{actual})",
          )
        }
      }
    }
  }
  for path in self.conffiles {
    if !seen.contains(path) {
      problems.push("\{path}: listed in conffiles but is not in the package")
    }
  }
  problems
}
