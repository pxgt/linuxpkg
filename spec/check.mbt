///|
/// Largest accepted epoch, the maximum of a signed 32-bit integer.
const MAX_EPOCH : Int32 = 2147483647

///|
/// Control characters other than newline and tab are never valid in text
/// fields.
fn has_bad_control(text : String, allow_newline : Bool) -> Bool {
  for c in text {
    if is_control(c) && !(allow_newline && (c == '\n' || c == '\t')) {
      return true
    }
  }
  false
}

///|
fn validate_text_line(
  text : String,
  field : String,
  max_length : Int32,
) -> Unit raise SpecError {
  if text.trim().length() == 0 {
    raise invalid(field, "must not be empty")
  }
  if text.length() > max_length {
    raise invalid(field, "must be at most \{max_length} characters long")
  }
  if has_bad_control(text, false) {
    raise invalid(field, "must be a single line without control characters")
  }
}

///|
fn validate_description(text : String) -> Unit raise SpecError {
  if text.trim().length() == 0 {
    raise invalid("description", "must not be empty")
  }
  if has_bad_control(text, true) {
    raise invalid("description", "must not contain control characters")
  }
  // The first line is the one-line summary shown by package managers.
  let summary = text.split("\n").next().unwrap().trim()
  if summary.length() == 0 {
    raise invalid("description", "the first line (summary) must not be empty")
  }
}

///|
fn validate_priority(priority : String) -> Unit raise SpecError {
  match priority {
    "required" | "important" | "standard" | "optional" | "extra" => ()
    _ =>
      raise invalid(
        "priority", "must be one of required, important, standard, optional or extra",
      )
  }
}

///|
fn validate_section(section : String) -> Unit raise SpecError {
  if section.length() == 0 {
    raise invalid("section", "must not be empty")
  }
  for c in section {
    if !(is_alnum(c) || c is ('/' | '_' | '.' | '+' | '-')) {
      raise invalid(
        "section",
        "contains \"\{c}\", only letters, digits, '/', '_', '.', '+' and '-' are allowed",
      )
    }
  }
}

///|
fn validate_url(url : String) -> Unit raise SpecError {
  if url.length() == 0 {
    raise invalid("homepage", "must not be empty")
  }
  for c in url {
    if is_control(c) || is_space(c) {
      raise invalid("homepage", "must not contain spaces or control characters")
    }
  }
}

///|
fn validate_script(name : String, script : String?) -> Unit raise SpecError {
  match script {
    None => ()
    Some(text) => {
      let field = "scripts.\{name}"
      if text.length() == 0 {
        raise invalid(field, "must not be empty, omit it instead")
      }
      for c in text {
        if c == '\u{0}' {
          raise invalid(field, "must not contain NUL characters")
        }
      }
    }
  }
}

///|
fn validate_relations(
  name : String,
  relations : Array[Dependency],
) -> Unit raise SpecError {
  for i, dep in relations {
    dep.validate(field="\{name}[\{i}]")
  }
}

///|
/// Check one entry. `field` prefixes error messages, for example
/// `entries[3]`.
pub fn Entry::validate(self : Entry, field~ : String) -> Unit raise SpecError {
  validate_install_path(self.path, field="\{field}.path")
  validate_mode(self.mode, field="\{field}.mode")
  validate_account(self.owner, field="\{field}.owner")
  validate_account(self.group, field="\{field}.group")
  match self.mtime {
    Some(t) if t < 0L => raise invalid("\{field}.mtime", "must not be negative")
    _ => ()
  }
  match self.kind {
    Symlink(target) => validate_link_target(target, field="\{field}.target")
    Dir =>
      if self.config {
        raise invalid("\{field}.config", "a directory cannot be a config file")
      }
    File(_) => ()
  }
}

///|
/// Check the file tree as a whole: no duplicate paths, and nothing installed
/// below a file or a symbolic link.
fn validate_tree(entries : Array[Entry]) -> Unit raise SpecError {
  let seen : Map[String, Int32] = Map([])
  for i, entry in entries {
    match seen.get(entry.path) {
      Some(first) =>
        raise invalid(
          "entries[\{i}].path",
          "\"\{entry.path}\" is already used by entries[\{first}]",
        )
      None => seen[entry.path] = i
    }
  }
  for i, entry in entries {
    // Visit every proper ancestor of the path: /usr, /usr/bin, ...
    let mut end = 1
    while end < entry.path.length() {
      if entry.path[end] == '/' {
        let ancestor = entry.path[0:end].to_owned()
        match seen.get(ancestor) {
          Some(j) if entries[j].kind != Dir =>
            raise invalid(
              "entries[\{i}].path",
              "\"\{entry.path}\" would be installed below \"\{ancestor}\", which entries[\{j}] makes a file or a symbolic link",
            )
          _ => ()
        }
      }
      end += 1
    }
  }
}

///|
/// Check every field of the package. Builders call this first, so a spec
/// that passes can always be turned into a package.
pub fn PackageSpec::validate(self : PackageSpec) -> Unit raise SpecError {
  validate_package_name(self.name)
  validate_version(self.version)
  validate_release(self.release)
  if self.epoch < 0 || self.epoch > MAX_EPOCH {
    raise invalid("epoch", "must be between 0 and \{MAX_EPOCH}")
  }
  validate_text_line(self.maintainer, "maintainer", 256)
  validate_description(self.description)
  match self.homepage {
    Some(url) => validate_url(url)
    None => ()
  }
  match self.license {
    Some(text) => validate_text_line(text, "license", 256)
    None => ()
  }
  match self.vendor {
    Some(text) => validate_text_line(text, "vendor", 256)
    None => ()
  }
  validate_section(self.section)
  validate_priority(self.priority)
  validate_relations("depends", self.depends)
  validate_relations("recommends", self.recommends)
  validate_relations("suggests", self.suggests)
  validate_relations("conflicts", self.conflicts)
  validate_relations("replaces", self.replaces)
  validate_relations("provides", self.provides)
  for i, entry in self.entries {
    entry.validate(field="entries[\{i}]")
  }
  validate_tree(self.entries)
  validate_script("pre_install", self.scripts.pre_install)
  validate_script("post_install", self.scripts.post_install)
  validate_script("pre_remove", self.scripts.pre_remove)
  validate_script("post_remove", self.scripts.post_remove)
  if self.mtime < 0L {
    raise invalid("mtime", "must not be negative")
  }
}
