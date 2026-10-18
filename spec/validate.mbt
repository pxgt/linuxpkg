///|
fn is_lower_or_digit(c : Char) -> Bool {
  c is ('a'..<='z' | '0'..<='9')
}

///|
fn is_alnum(c : Char) -> Bool {
  c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9')
}

///|
fn is_control(c : Char) -> Bool {
  let code = c.to_int()
  code < 0x20 || code == 0x7f
}

///|
/// Longest name, version or release accepted. It keeps headers and file names
/// in every package format comfortably inside their own limits.
const MAX_FIELD_LENGTH : Int32 = 128

///|
/// Longest install path accepted (the Linux `PATH_MAX`).
const MAX_PATH_LENGTH : Int32 = 4096

///|
/// Check a package name. Names are lowercase, at least two characters long,
/// start with a letter or digit and continue with letters, digits, `+`, `-`
/// or `.`. This is the Debian rule, and RPM accepts everything it allows.
///
/// # Example
/// ```mbt check
/// test {
///   @spec.validate_package_name("hello-world")
///   try @spec.validate_package_name("Hello") catch {
///     err => inspect(err, content="name: must be lowercase")
///   } noraise {
///     _ => fail("expected an error")
///   }
/// }
/// ```
pub fn validate_package_name(name : String) -> Unit raise SpecError {
  if name.length() < 2 {
    raise invalid("name", "must be at least two characters long")
  }
  if name.length() > MAX_FIELD_LENGTH {
    raise invalid("name", "must be at most \{MAX_FIELD_LENGTH} characters long")
  }
  for c in name {
    if c is ('A'..<='Z') {
      raise invalid("name", "must be lowercase")
    }
  }
  if !is_lower_or_digit(name[0].unsafe_to_char()) {
    raise invalid("name", "must start with a letter or a digit")
  }
  for c in name {
    if !(is_lower_or_digit(c) || c is ('+' | '-' | '.')) {
      raise invalid(
        "name",
        "contains \"\{c}\", only letters, digits, '+', '-' and '.' are allowed",
      )
    }
  }
}

///|
fn validate_version_chars(
  field : String,
  text : String,
) -> Unit raise SpecError {
  if text.length() > MAX_FIELD_LENGTH {
    raise invalid(field, "must be at most \{MAX_FIELD_LENGTH} characters long")
  }
  for c in text {
    if !(is_alnum(c) || c is ('.' | '+' | '~')) {
      raise invalid(
        field,
        "contains \"\{c}\", only letters, digits, '.', '+' and '~' are allowed (use '~' for pre-releases such as 1.0~rc1)",
      )
    }
  }
}

///|
/// Check the upstream version. It must start with a digit and may continue
/// with letters, digits, `.`, `+` and `~`. A hyphen is rejected because it
/// separates the release in both deb and rpm; write `1.0~rc1` instead of
/// `1.0-rc1`.
pub fn validate_version(version : String) -> Unit raise SpecError {
  if version.length() == 0 {
    raise invalid("version", "must not be empty")
  }
  if !(version[0].unsafe_to_char() is ('0'..<='9')) {
    raise invalid("version", "must start with a digit")
  }
  validate_version_chars("version", version)
}

///|
/// Check the packaging revision (RPM *release*, Debian *revision*). It may
/// contain letters, digits, `.`, `+` and `~`.
pub fn validate_release(release : String) -> Unit raise SpecError {
  if release.length() == 0 {
    raise invalid("release", "must not be empty")
  }
  validate_version_chars("release", release)
}

///|
/// Check an install path such as `/usr/bin/hello`. It must be absolute,
/// normalized (no `.`, `..`, empty segments or trailing slash), and free of
/// control characters. `field` is only used in the error message.
///
/// # Example
/// ```mbt check
/// test {
///   @spec.validate_install_path("/usr/bin/hello", field="dst")
///   try @spec.validate_install_path("/usr/../etc/passwd", field="dst") catch {
///     err => inspect(err, content="dst: must not contain \"..\"")
///   } noraise {
///     _ => fail("expected an error")
///   }
/// }
/// ```
pub fn validate_install_path(
  path : String,
  field~ : String,
) -> Unit raise SpecError {
  if path.length() == 0 {
    raise invalid(field, "must not be empty")
  }
  if path.length() > MAX_PATH_LENGTH {
    raise invalid(field, "must be at most \{MAX_PATH_LENGTH} characters long")
  }
  for c in path {
    if is_control(c) {
      raise invalid(field, "must not contain control characters")
    }
  }
  if path[0] != '/' {
    raise invalid(field, "must be an absolute path starting with '/'")
  }
  if path == "/" {
    raise invalid(field, "must not be the root directory")
  }
  if path[path.length() - 1] == '/' {
    raise invalid(field, "must not end with '/'")
  }
  for segment in path[1:].split("/") {
    let segment = segment.to_owned()
    if segment == "" {
      raise invalid(field, "must not contain empty segments (\"//\")")
    }
    if segment == ".." {
      raise invalid(field, "must not contain \"..\"")
    }
    if segment == "." {
      raise invalid(field, "must not contain \".\"")
    }
  }
}

///|
/// Check a symbolic link target. Unlike install paths, link targets may be
/// relative and may use `..`, but they may not be empty or contain control
/// characters.
pub fn validate_link_target(
  target : String,
  field~ : String,
) -> Unit raise SpecError {
  if target.length() == 0 {
    raise invalid(field, "must not be empty")
  }
  if target.length() > MAX_PATH_LENGTH {
    raise invalid(field, "must be at most \{MAX_PATH_LENGTH} characters long")
  }
  for c in target {
    if is_control(c) {
      raise invalid(field, "must not contain control characters")
    }
  }
}

///|
/// Check permission bits (`0` to `0o7777`).
pub fn validate_mode(mode : Int32, field~ : String) -> Unit raise SpecError {
  if mode < 0 || mode > 0o7777 {
    raise invalid(
      field,
      "must be between 0 and 07777 (octal), got \{mode.to_string(radix=8)}",
    )
  }
}

///|
/// Check a user or group name: 1 to 32 characters from letters, digits, `_`,
/// `-` and `.`.
pub fn validate_account(name : String, field~ : String) -> Unit raise SpecError {
  if name.length() == 0 || name.length() > 32 {
    raise invalid(field, "must be 1 to 32 characters long")
  }
  for c in name {
    if !(is_alnum(c) || c is ('_' | '-' | '.')) {
      raise invalid(
        field,
        "contains \"\{c}\", only letters, digits, '_', '-' and '.' are allowed",
      )
    }
  }
}
