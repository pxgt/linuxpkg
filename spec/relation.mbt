///|
/// The operator as Debian writes it inside parentheses: `<<`, `<=`, `=`, `>=`
/// or `>>`.
pub fn VersionOp::deb_symbol(self : VersionOp) -> String {
  match self {
    Lt => "<<"
    Le => "<="
    Eq => "="
    Ge => ">="
    Gt => ">>"
  }
}

///|
/// The operator as RPM writes it: `<`, `<=`, `=`, `>=` or `>`.
pub fn VersionOp::rpm_symbol(self : VersionOp) -> String {
  match self {
    Lt => "<"
    Le => "<="
    Eq => "="
    Ge => ">="
    Gt => ">"
  }
}

///|
fn parse_op(text : StringView) -> VersionOp? {
  match text {
    "<<" | "<" => Some(Lt)
    "<=" => Some(Le)
    "=" | "==" => Some(Eq)
    ">=" => Some(Ge)
    ">>" | ">" => Some(Gt)
    _ => None
  }
}

///|
fn is_space(c : Char) -> Bool {
  c is (' ' | '\t' | '\n' | '\r')
}

///|
fn validate_dependency_name(
  name : String,
  field : String,
) -> Unit raise SpecError {
  if name.length() == 0 {
    raise invalid(field, "package name must not be empty")
  }
  for c in name {
    if is_control(c) || is_space(c) || c is ('(' | ')' | ',' | '|') {
      raise invalid(
        field,
        "package name \"\{name}\" contains \"\{c}\", alternatives and lists are not supported, write one entry per package",
      )
    }
  }
}

///|
fn validate_dependency_version(
  version : String,
  field : String,
) -> Unit raise SpecError {
  if version.length() == 0 {
    raise invalid(field, "version after the operator must not be empty")
  }
  if version.length() > MAX_FIELD_LENGTH {
    raise invalid(
      field,
      "version must be at most \{MAX_FIELD_LENGTH} characters long",
    )
  }
  for c in version {
    if !(is_alnum(c) || c is ('.' | '+' | '~' | ':' | '_' | '-')) {
      raise invalid(field, "version \"\{version}\" contains \"\{c}\"")
    }
  }
}

///|
/// Check a relation that was built by hand.
pub fn Dependency::validate(
  self : Dependency,
  field~ : String,
) -> Unit raise SpecError {
  validate_dependency_name(self.name, field)
  match self.constraint {
    Some((_, version)) => validate_dependency_version(version, field)
    None => ()
  }
}

///|
/// Parse a relation written the Debian way (`libc6 (>= 2.31)`), the RPM way
/// (`libc6 >= 2.31`) or without any version (`bash`). `<` and `>` are strict
/// comparisons, `<<` and `>>` are accepted as synonyms for them. `field` only
/// appears in error messages.
///
/// # Example
/// ```mbt check
/// test {
///   let dep = @spec.Dependency::parse("libc6 (>= 2.31)")
///   assert_eq(dep.name, "libc6")
///   assert_eq(dep.constraint, Some((@spec.VersionOp::Ge, "2.31")))
/// }
/// ```
pub fn Dependency::parse(
  text : String,
  field~ : String = "dependency",
) -> Dependency raise SpecError {
  let text = text.trim()
  let mut name_end = 0
  for c in text {
    if is_space(c) || c is ('(' | '<' | '>' | '=' | ',' | '|') {
      break
    }
    name_end += c.utf16_len()
  }
  let name = text[0:name_end].to_owned()
  validate_dependency_name(name, field)
  let mut rest = text[name_end:].trim()
  if rest.length() == 0 {
    return { name, constraint: None, }
  }
  if rest[0] == '|' || rest[0] == ',' {
    raise invalid(
      field, "alternatives ('|') and lists (',') are not supported, write one entry per package",
    )
  }
  if rest[0] == '(' {
    guard rest[rest.length() - 1] == ')' else {
      raise invalid(field, "missing ')' in \"\{text}\"")
    }
    rest = rest[1:rest.length() - 1].trim()
  }
  let mut op_end = 0
  for c in rest {
    if !(c is ('<' | '>' | '=')) {
      break
    }
    op_end += 1
  }
  let op = match parse_op(rest[0:op_end]) {
    Some(op) => op
    None =>
      raise invalid(
        field,
        "expected one of <<, <, <=, =, >=, >, >> before the version in \"\{text}\"",
      )
  }
  let version = rest[op_end:].trim().to_owned()
  validate_dependency_version(version, field)
  { name, constraint: Some((op, version)), }
}

///|
/// Render the relation in Debian syntax, for example `libc6 (>= 2.31)`.
pub fn Dependency::deb_string(self : Dependency) -> String {
  match self.constraint {
    Some((op, version)) => "\{self.name} (\{op.deb_symbol()} \{version})"
    None => self.name
  }
}

///|
/// Render the relation in RPM syntax, for example `libc6 >= 2.31`.
pub fn Dependency::rpm_string(self : Dependency) -> String {
  match self.constraint {
    Some((op, version)) => "\{self.name} \{op.rpm_symbol()} \{version}"
    None => self.name
  }
}
