///|
/// Keys whose plain scalar must stay text. YAML 1.2 turns `1.10` into the
/// number 1.1 and `0755` into 755; nFPM (Go) keeps the text of a version and
/// reads `0755` as octal. The YAML reader here does not keep the text of a
/// number, so these values are put in quotes before it sees them.
let text_keys : Array[String] = [
  "version", "release", "epoch", "prerelease", "version_metadata", "mode",
]

///|
fn is_number_start(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_number_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') ||
  (c >= 'a' && c <= 'f') ||
  (c >= 'A' && c <= 'F') ||
  c == '.' ||
  c == '_' ||
  c == 'x' ||
  c == 'X' ||
  c == 'o' ||
  c == 'O'
}

///|
/// Does `key:` start at `at` of `line` as a key (start of line, after
/// whitespace, `{` or `,`)?
fn key_at(line : String, at : Int32, key : String) -> Bool {
  if at + key.length() >= line.length() {
    return false
  }
  if line[at + key.length()] != ':' {
    return false
  }
  if line[at:at + key.length()].to_owned() != key {
    return false
  }
  if at == 0 {
    return true
  }
  let before = line[at - 1]
  before == ' ' || before == '\t' || before == '{' || before == ','
}

///|
/// Where the comment of a line starts (a `#` after whitespace, outside quotes),
/// or the length of the line.
fn comment_start(line : String) -> Int32 {
  let mut quote = ' '
  let mut in_quote = false
  for i in 0..<line.length() {
    let c = line[i].unsafe_to_char()
    if in_quote {
      if c == quote {
        in_quote = false
      }
    } else if c == '"' || c == '\'' {
      quote = c
      in_quote = true
    } else if c == '#' && (i == 0 || line[i - 1] == ' ' || line[i - 1] == '\t') {
      return i
    }
  }
  line.length()
}

///|
/// Quote the value of every `key: 123`-style entry of `text_keys` that is a
/// bare number, line by line. Block scalars (`|`, `>`) are left alone.
fn quote_numbers(text : String) -> String {
  let out : Array[String] = []
  let mut block_indent = -1
  for raw in text.split("\n") {
    let line = raw.to_owned()
    let trimmed = line.trim_start().to_owned()
    let indent = line.length() - trimmed.length()
    if block_indent >= 0 {
      if trimmed.length() == 0 || indent > block_indent {
        out.push(line)
        continue
      }
      block_indent = -1
    }
    let mut changed = line
    for key in text_keys {
      let mut from = 0
      while from < changed.length() {
        let at = match changed[from:].find(key + ":") {
          Some(n) => from + n
          None => break
        }
        if at >= comment_start(changed) {
          break
        }
        if !key_at(changed, at, key) {
          from = at + 1
          continue
        }
        let mut v = at + key.length() + 1
        while v < changed.length() && (changed[v] == ' ' || changed[v] == '\t') {
          v += 1
        }
        let mut e = v
        while e < changed.length() &&
              is_number_char(changed[e].unsafe_to_char()) {
          e += 1
        }
        let ends_value = e >= changed.length() ||
          changed[e] == ' ' ||
          changed[e] == '\t' ||
          changed[e] == '#' ||
          changed[e] == ',' ||
          changed[e] == '}' ||
          changed[e] == '\r'
        if e > v && is_number_start(changed[v].unsafe_to_char()) && ends_value {
          let token = changed[v:e].to_owned()
          changed = changed[0:v].to_owned() +
            "\"" +
            token +
            "\"" +
            changed[e:].to_owned()
          from = e + 2
        } else {
          from = at + 1
        }
      }
    }
    let code = changed.trim_end().to_owned()
    if code.has_suffix("|") ||
      code.has_suffix(">") ||
      code.has_suffix("|-") ||
      code.has_suffix(">-") ||
      code.has_suffix("|+") ||
      code.has_suffix(">+") {
      block_indent = indent
    }
    out.push(changed)
  }
  out.join("\n")
}
