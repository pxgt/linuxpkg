///|
/// `major.minor.patch`, the pre-release and the build metadata of a version
/// written like `v1.2.3-rc.1+git`.
priv struct Semver {
  major : Int64
  minor : Int64
  patch : Int64
  prerelease : String
  metadata : String
}

///|
fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_ident_char(c : Char) -> Bool {
  is_digit_char(c) ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '-'
}

///|
/// Dot separated identifiers of letters, digits and `-`. Numeric identifiers
/// of a pre-release must not have a leading zero (semver 2.0.0).
fn valid_idents(text : String, is_prerelease : Bool) -> Bool {
  if text.length() == 0 {
    return false
  }
  for part in text.split(".") {
    let part = part.to_owned()
    if part.length() == 0 {
      return false
    }
    let mut all_digits = true
    for c in part {
      if !is_ident_char(c) {
        return false
      }
      if !is_digit_char(c) {
        all_digits = false
      }
    }
    if is_prerelease && all_digits && part.length() > 1 && part[0] == '0' {
      return false
    }
  }
  true
}

///|
/// Split a version like Masterminds/semver `NewVersion`, which nFPM uses: an
/// optional `v`, one to three numbers (missing ones are zero), `-pre-release`
/// and `+metadata`. `None` when the text is not a version; nFPM then leaves the
/// version as it is.
fn parse_semver(text : String) -> Semver? {
  let mut rest = text
  if rest.length() > 0 && (rest[0] == 'v' || rest[0] == 'V') {
    rest = rest[1:].to_owned()
  }
  let mut metadata = ""
  match rest.find("+") {
    Some(at) => {
      metadata = rest[at + 1:].to_owned()
      rest = rest[0:at].to_owned()
      if !valid_idents(metadata, false) {
        return None
      }
    }
    None => ()
  }
  let mut prerelease = ""
  match rest.find("-") {
    Some(at) => {
      prerelease = rest[at + 1:].to_owned()
      rest = rest[0:at].to_owned()
      if !valid_idents(prerelease, true) {
        return None
      }
    }
    None => ()
  }
  let numbers : Array[Int64] = []
  let parts = rest.split(".").map(p => p.to_owned()).collect()
  if parts.length() == 0 || parts.length() > 3 {
    return None
  }
  for part in parts {
    if part.length() == 0 || part.length() > 15 {
      return None
    }
    let mut value = 0L
    for c in part {
      if !is_digit_char(c) {
        return None
      }
      value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    numbers.push(value)
  }
  while numbers.length() < 3 {
    numbers.push(0L)
  }
  Some({
    major: numbers[0],
    minor: numbers[1],
    patch: numbers[2],
    prerelease,
    metadata,
  })
}

///|
/// The version, pre-release and metadata the way nFPM's `WithDefaults`
/// settles them (`version_schema: none` keeps the file's values).
fn settle_version(
  version : String,
  prerelease : String,
  metadata : String,
  schema : String,
) -> (String, String, String) {
  if schema == "none" {
    return (version, prerelease, metadata)
  }
  match parse_semver(version) {
    Some(v) =>
      (
        "\{v.major}.\{v.minor}.\{v.patch}",
        if prerelease == "" {
          v.prerelease
        } else {
          prerelease
        },
        if metadata == "" {
          v.metadata
        } else {
          metadata
        },
      )
    None => (version, prerelease, metadata)
  }
}
