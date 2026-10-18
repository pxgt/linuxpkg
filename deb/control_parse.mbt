///|
/// Parse a `control` file (a single deb822 paragraph) into its fields, in
/// file order. Continuation lines are joined with newlines and a line that
/// holds only `.` becomes an empty line, so a multi-line `Description` comes
/// back as it was written before formatting.
pub fn parse_control(text : String) -> Array[(String, String)] raise DebError {
  let fields : Array[(String, String)] = []
  let mut seen_blank = false
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.has_prefix("#") {
      continue
    }
    if line.trim().length() == 0 {
      seen_blank = true
      continue
    }
    if seen_blank {
      raise DebError::Corrupt(
        message="control file has more than one paragraph",
      )
    }
    if line.has_prefix(" ") || line.has_prefix("\t") {
      if fields.length() == 0 {
        raise DebError::Corrupt(
          message="control file starts with a continuation line",
        )
      }
      let (key, value) = fields[fields.length() - 1]
      let body = line[1:].to_owned()
      let body = if body.trim() == "." { "" } else { body }
      fields[fields.length() - 1] = (key, "\{value}\n\{body}")
      continue
    }
    match line.find(":") {
      Some(at) if at > 0 => {
        let key = line[0:at].to_owned()
        for c in key {
          if c == ' ' || c == '\t' {
            raise DebError::Corrupt(
              message="invalid control field name \"\{key}\"",
            )
          }
        }
        fields.push((key, line[at + 1:].trim().to_owned()))
      }
      _ =>
        raise DebError::Corrupt(
          message="control line is not \"Field: value\": \"\{line}\"",
        )
    }
  }
  fields
}

///|
/// Parse the lines of an `md5sums` file into `(absolute path, digest)`.
pub fn parse_md5sums(text : String) -> Array[(String, String)] raise DebError {
  let sums : Array[(String, String)] = []
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.length() == 0 {
      continue
    }
    if line.length() < 35 ||
      line[32] != ' ' ||
      (line[33] != ' ' && line[33] != '*') {
      raise DebError::Corrupt(message="bad md5sums line: \"\{line}\"")
    }
    let digest = line[0:32].to_owned()
    for c in digest {
      if !(c is ('0'..<='9' | 'a'..<='f')) {
        raise DebError::Corrupt(
          message="md5sums digest is not lowercase hexadecimal: \"\{line}\"",
        )
      }
    }
    sums.push(("/" + line[34:].to_owned(), digest))
  }
  sums
}
