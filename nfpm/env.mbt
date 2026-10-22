///|
/// Why an nFPM configuration could not be converted. The text names the
/// field (`contents[2].src`) and says what is wrong or not supported.
pub(all) suberror NfpmError {
  Invalid(String)
} derive(Eq, Debug)

///|
pub impl Show for NfpmError with fn output(self, logger) {
  match self {
    Invalid(message) => logger.write_string(message)
  }
}

///|
fn invalid(field : String, message : String) -> NfpmError {
  if field == "" {
    Invalid(message)
  } else {
    Invalid("\{field}: \{message}")
  }
}

///|
fn is_shell_special(c : Int32) -> Bool {
  c == '*'.to_int() ||
  c == '#'.to_int() ||
  c == '$'.to_int() ||
  c == '@'.to_int() ||
  c == '!'.to_int() ||
  c == '?'.to_int() ||
  c == '-'.to_int() ||
  (c >= '0'.to_int() && c <= '9'.to_int())
}

///|
fn is_name_char(c : Int32) -> Bool {
  c == '_'.to_int() ||
  (c >= '0'.to_int() && c <= '9'.to_int()) ||
  (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
  (c >= 'A'.to_int() && c <= 'Z'.to_int())
}

///|
/// The variable name at the start of `s` (the text after a `$`) and how many
/// characters it took, like Go's `os.getShellName`.
fn shell_name(s : String) -> (String, Int32) {
  let first = s[0].to_int()
  if first == '{'.to_int() {
    if s.length() > 2 && is_shell_special(s[1].to_int()) && s[2] == '}' {
      return (s[1:2].to_owned(), 3)
    }
    for i in 1..<s.length() {
      if s[i] == '}' {
        if i == 1 {
          // Bad syntax: "${}" is dropped.
          return ("", 2)
        }
        return (s[1:i].to_owned(), i + 1)
      }
    }
    // Bad syntax: "${" without a closing brace is dropped.
    return ("", 1)
  }
  if is_shell_special(first) {
    return (s[0:1].to_owned(), 1)
  }
  let mut i = 0
  while i < s.length() && is_name_char(s[i].to_int()) {
    i += 1
  }
  (s[0:i].to_owned(), i)
}

///|
/// Replace `$name` and `${name}` by `lookup(name)` exactly like Go's
/// `os.Expand`, which is what nFPM uses: a `$` that is not followed by a name
/// stays; `${}` and an unclosed `${` are dropped; `$1`, `$$`, `$*` and the like
/// are single-character names; there is no `${name:-default}`, the whole text
/// between the braces is the name.
///
/// # Example
/// ```mbt check
/// test {
///   let lookup = (name : String) => if name == "V" { "1.2" } else { "" }
///   assert_eq(@nfpm.expand("v$V-${V}x $", lookup), "v1.2-1.2x $")
/// }
/// ```
pub fn expand(s : String, lookup : (String) -> String) -> String {
  let out = StringBuilder()
  let mut i = 0
  let mut j = 0
  while j < s.length() {
    if s[j] == '$' && j + 1 < s.length() {
      out.write_string(s[i:j].to_owned())
      let (name, width) = shell_name(s[j + 1:].to_owned())
      if name == "" && width > 0 {
        // Invalid syntax: the characters are eaten.
        ()
      } else if name == "" {
        out.write_char('$')
      } else {
        out.write_string(lookup(name))
      }
      j += width
      i = j + 1
    }
    j += 1
  }
  if i == 0 && out.is_empty() {
    return s
  }
  out.write_string(s[i:].to_owned())
  out.to_string()
}
