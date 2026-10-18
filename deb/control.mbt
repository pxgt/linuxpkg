///|
/// Lowercase hexadecimal MD5 digest of `data`.
fn md5_hex(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.md5(data))
}

///|
/// The Debian version string: `[epoch:]version-release`.
pub fn version_string(spec : @spec.PackageSpec) -> String {
  let base = "\{spec.version}-\{spec.release}"
  if spec.epoch > 0 {
    "\{spec.epoch}:\{base}"
  } else {
    base
  }
}

///|
/// The conventional file name of the package, for example
/// `hello_1.0.0-1_amd64.deb`. The epoch is not part of file names.
pub fn file_name(spec : @spec.PackageSpec) -> String {
  "\{spec.name}_\{spec.version}-\{spec.release}_\{spec.arch.deb_name()}.deb"
}

///|
/// Format a free-form description as a control file field value: the first
/// line is the summary, continuation lines start with one space and blank
/// lines are written as a single dot.
fn render_description(text : String) -> String {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.trim_end().to_owned())
  }
  // Drop trailing blank lines.
  while lines.length() > 1 && lines[lines.length() - 1] == "" {
    ignore(lines.pop())
  }
  let out = StringBuilder()
  for i, line in lines {
    if i == 0 {
      out.write_string(line.trim_start().to_owned())
    } else if line.trim() == "" {
      out.write_string("\n .")
    } else {
      out.write_string("\n \{line}")
    }
  }
  out.to_string()
}

///|
fn add_field(out : StringBuilder, key : String, value : String) -> Unit {
  out.write_string("\{key}: \{value}\n")
}

///|
fn add_relations(
  out : StringBuilder,
  key : String,
  relations : Array[@spec.Dependency],
) -> Unit {
  if relations.length() > 0 {
    add_field(out, key, relations.map(r => r.deb_string()).join(", "))
  }
}

///|
/// Total size of the regular files in KiB, rounded up. This is the
/// `Installed-Size` that tools like `apt` show.
fn installed_size(spec : @spec.PackageSpec) -> Int32 {
  let mut bytes = 0
  for entry in spec.entries {
    match entry.kind {
      File(content) => bytes += content.length()
      _ => ()
    }
  }
  (bytes + 1023) / 1024
}

///|
/// Render the `control` file for a package. The spec is assumed to be valid.
///
/// # Example
/// ```mbt check
/// test {
///   let spec = @spec.PackageSpec::new(
///     name="hello",
///     version="1.0",
///     arch=@spec.Arch::Amd64,
///     maintainer="Jane <jane@example.org>",
///     description="Says hello",
///   )
///   inspect(
///     @deb.control_file(spec),
///     content=(
///       #|Package: hello
///       #|Version: 1.0-1
///       #|Architecture: amd64
///       #|Maintainer: Jane <jane@example.org>
///       #|Installed-Size: 0
///       #|Section: misc
///       #|Priority: optional
///       #|Description: Says hello
///       #|
///     ),
///   )
/// }
/// ```
pub fn control_file(spec : @spec.PackageSpec) -> String {
  let out = StringBuilder()
  add_field(out, "Package", spec.name)
  add_field(out, "Version", version_string(spec))
  add_field(out, "Architecture", spec.arch.deb_name())
  add_field(out, "Maintainer", spec.maintainer)
  add_field(out, "Installed-Size", installed_size(spec).to_string())
  add_relations(out, "Depends", spec.depends)
  add_relations(out, "Recommends", spec.recommends)
  add_relations(out, "Suggests", spec.suggests)
  add_relations(out, "Conflicts", spec.conflicts)
  add_relations(out, "Replaces", spec.replaces)
  add_relations(out, "Provides", spec.provides)
  add_field(out, "Section", spec.section)
  add_field(out, "Priority", spec.priority)
  match spec.homepage {
    Some(url) => add_field(out, "Homepage", url)
    None => ()
  }
  add_field(out, "Description", render_description(spec.description))
  out.to_string()
}
