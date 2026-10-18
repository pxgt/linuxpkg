///|
/// Everything before the last `/` or `\`, or "" when there is none.
fn dirname(path : String) -> String {
  let mut cut = -1
  for i in 0..<path.length() {
    if path[i] == '/' || path[i] == '\\' {
      cut = i
    }
  }
  if cut < 0 {
    ""
  } else if cut == 0 {
    "/"
  } else {
    path[0:cut].to_owned()
  }
}

///|
fn is_absolute(path : String) -> Bool {
  path.has_prefix("/") ||
  path.has_prefix("\\") ||
  (path.length() >= 2 && path[1] == ':' && path[0] is ('a'..<='z' | 'A'..<='Z'))
}

///|
/// Resolve `path` relative to `base` (a directory, "" for the current one).
fn join_path(base : String, path : String) -> String {
  if base == "" || is_absolute(path) {
    path
  } else if base.has_suffix("/") {
    base + path
  } else {
    base + "/" + path
  }
}

///|
fn describe_io(error : @fs.IOError, what : String) -> String {
  match error {
    IOError(message) => "\{what}: \{message}"
  }
}

///|
fn read_bytes(path : String) -> Bytes raise CliError {
  @fs.read_file_to_bytes(path) catch {
    err => raise Failed(describe_io(err, "cannot read \"\{path}\""))
  }
}

///|
fn write_bytes(path : String, data : Bytes) -> Unit raise CliError {
  @fs.write_bytes_to_file(path, data) catch {
    err => raise Failed(describe_io(err, "cannot write \"\{path}\""))
  }
}

///|
/// Create `path` when it does not exist yet.
fn ensure_dir(path : String) -> Unit raise CliError {
  if path == "" || path == "." || path == "/" || @fs.path_exists(path) {
    return
  }
  let parent = dirname(path)
  if parent != path {
    ensure_dir(parent)
  }
  @fs.create_dir(path) catch {
    err => raise Failed(describe_io(err, "cannot create directory \"\{path}\""))
  }
}

///|
/// `SOURCE_DATE_EPOCH` as a timestamp, if set. See
/// https://reproducible-builds.org/specs/source-date-epoch/
fn source_date_epoch() -> Int64? raise CliError {
  match @env.get_env_var("SOURCE_DATE_EPOCH") {
    None | Some("") => None
    Some(text) => {
      let mut value = 0L
      if text.length() > 15 {
        raise Failed(
          "SOURCE_DATE_EPOCH must be a non-negative integer, got \"\{text}\"",
        )
      }
      for c in text {
        guard c is ('0'..<='9') else {
          raise Failed(
            "SOURCE_DATE_EPOCH must be a non-negative integer, got \"\{text}\"",
          )
        }
        value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
      }
      Some(value)
    }
  }
}
