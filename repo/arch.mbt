///|
/// Add `%TITLE%` and its values, one per line, when there are any.
fn desc_section(
  out : StringBuilder,
  title : String,
  values : Array[String],
) -> Unit {
  let kept = values.filter(v => v != "")
  if kept.length() > 0 {
    out.write_string("%\{title}%\n")
    for value in kept {
      out.write_string(value)
      out.write_char('\n')
    }
    out.write_char('\n')
  }
}

///|
fn desc_one(out : StringBuilder, title : String, value : String?) -> Unit {
  match value {
    Some(text) => desc_section(out, title, [text])
    None => ()
  }
}

///|
fn arch_read(file : PackageFile) -> @arch.ArchPackage raise RepoError {
  if !file.name.contains(".pkg.tar") {
    raise Invalid(file=file.name, message="the name must contain .pkg.tar")
  }
  for c in file.name {
    if c == '/' || c == '\\' || c == ' ' || c.to_int() < 32 {
      raise Invalid(
        file=file.name,
        message="the name must be a plain file name without spaces or slashes",
      )
    }
  }
  @arch.read(file.data) catch {
    err => raise Invalid(file=file.name, message="\{err}")
  }
}

///|
/// The `desc` file of a package in a pacman database, with the fields and
/// in the order that `repo-add` writes them. `signature` is the content of
/// the detached `.sig` of the package, if there is one.
fn arch_desc(
  file : PackageFile,
  pkg : @arch.ArchPackage,
  signature : Bytes?,
) -> (String, String) raise RepoError {
  guard pkg.field("pkgname") is Some(name) &&
    pkg.field("pkgver") is Some(version) &&
    pkg.field("arch") is Some(_) else {
    raise Invalid(
      file=file.name,
      message=".PKGINFO lacks pkgname, pkgver or arch",
    )
  }
  let out = StringBuilder()
  desc_one(out, "FILENAME", Some(file.name))
  desc_one(out, "NAME", Some(name))
  desc_one(out, "BASE", pkg.field("pkgbase"))
  desc_one(out, "VERSION", Some(version))
  desc_one(out, "DESC", pkg.field("pkgdesc"))
  desc_section(out, "GROUPS", pkg.fields("group"))
  desc_one(out, "CSIZE", Some(file.data.length().to_string()))
  desc_one(out, "ISIZE", pkg.field("size"))
  desc_one(out, "MD5SUM", Some(md5_hex(file.data)))
  desc_one(out, "SHA256SUM", Some(sha256_hex(file.data)))
  match signature {
    Some(sig) => desc_one(out, "PGPSIG", Some(@base64.encode(sig[:])))
    None => ()
  }
  desc_one(out, "URL", pkg.field("url"))
  desc_section(out, "LICENSE", pkg.fields("license"))
  desc_one(out, "ARCH", pkg.field("arch"))
  desc_one(out, "BUILDDATE", pkg.field("builddate"))
  desc_one(out, "PACKAGER", pkg.field("packager"))
  desc_section(out, "REPLACES", pkg.fields("replaces"))
  desc_section(out, "CONFLICTS", pkg.fields("conflict"))
  desc_section(out, "PROVIDES", pkg.fields("provides"))
  desc_section(out, "DEPENDS", pkg.fields("depend"))
  desc_section(out, "OPTDEPENDS", pkg.fields("optdepend"))
  desc_section(out, "MAKEDEPENDS", pkg.fields("makedepend"))
  desc_section(out, "CHECKDEPENDS", pkg.fields("checkdepend"))
  let files = StringBuilder()
  files.write_string("%FILES%\n")
  for entry in pkg.entries {
    let path = entry.path
    if path.has_prefix(".") {
      continue
    }
    files.write_string(path)
    if entry.kind is Dir && !path.has_suffix("/") {
      files.write_char('/')
    }
    files.write_char('\n')
  }
  files.write_char('\n')
  ("\{name}-\{version}", out.to_string() + "\u{0}" + files.to_string())
}

///|
fn check_repo_name(name : String) -> Unit raise RepoError {
  if name == "" {
    raise Invalid(file="name", message="the repository name must not be empty")
  }
  for c in name {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.' ||
      c == '+'
    if !ok {
      raise Invalid(
        file="name",
        message="\"\{name}\": use only letters, digits and - _ . +",
      )
    }
  }
}

///|
fn arch_database(
  entries : Array[(String, Array[(String, String)])],
  date : Int64,
  label : String,
) -> Bytes raise RepoError {
  let items : Array[@tar.Entry] = []
  for entry in entries {
    items.push(@tar.Entry::dir(entry.0 + "/", mtime=date))
    for file in entry.1 {
      items.push(
        @tar.Entry::file(
          entry.0 + "/" + file.0,
          @utf8.encode(file.1),
          mtime=date,
        ),
      )
    }
  }
  let tar = @tar.build(items) catch {
    err => raise Invalid(file=label, message="\{err}")
  }
  @compress.compress(tar, Gzip) catch {
    err => raise Invalid(file=label, message="\{err}")
  }
}

///|
/// The files of a pacman repository called `name` for the given Arch Linux
/// packages: `<name>.db.tar.gz` and `<name>.files.tar.gz` (gzip tars with a
/// `<package>-<version>/desc` for every package, and a `files` list in the
/// files database), as `repo-add` writes them, plus the copies `<name>.db`
/// and `<name>.files` that pacman asks for (a static web server such as GitHub
/// Pages has no symbolic links). `signatures` holds the detached `.sig`
/// files by name (`<package>.sig`); a package with one gets a `%PGPSIG%`
/// entry. `date` is the time of the archive entries. Nothing is signed; see
/// `sign_arch`.
pub fn arch_index(
  packages : Array[PackageFile],
  signatures : Array[PackageFile],
  name~ : String,
  date~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  check_repo_name(name)
  let sorted = sorted_by_name(packages)
  check_unique(sorted)
  let db : Array[(String, Array[(String, String)])] = []
  let files_db : Array[(String, Array[(String, String)])] = []
  for file in sorted {
    let pkg = arch_read(file)
    let signature = find_package_file(signatures, file.name + ".sig")
    let (dir, text) = arch_desc(file, pkg, signature)
    let parts = text.split("\u{0}").map(p => p.to_owned()).collect()
    db.push((dir, [("desc", parts[0])]))
    files_db.push((dir, [("desc", parts[0]), ("files", parts[1])]))
  }
  db.sort_by((a, b) => text_compare(a.0, b.0))
  files_db.sort_by((a, b) => text_compare(a.0, b.0))
  for i in 1..<db.length() {
    if db[i].0 == db[i - 1].0 {
      raise Invalid(
        file=db[i].0,
        message="two packages have the same name and version",
      )
    }
  }
  let db_gz = arch_database(db, date, "\{name}.db.tar.gz")
  let files_gz = arch_database(files_db, date, "\{name}.files.tar.gz")
  [
    ("\{name}.db.tar.gz", db_gz),
    ("\{name}.db", db_gz),
    ("\{name}.files.tar.gz", files_gz),
    ("\{name}.files", files_gz),
  ]
}

///|
fn find_package_file(files : Array[PackageFile], name : String) -> Bytes? {
  for file in files {
    if file.name == name {
      return Some(file.data)
    }
  }
  None
}

///|
/// Sign the databases of a pacman repository (the output of `arch_index`)
/// with a detached signature each, `<name>.db.tar.gz.sig` and
/// `<name>.files.tar.gz.sig`, plus the copies `<name>.db.sig` and
/// `<name>.files.sig` that pacman fetches.
pub fn sign_arch(
  files : Array[(String, Bytes)],
  key : @sign.SigningKey,
  created~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let result : Array[(String, Bytes)] = []
  let time = key.signing_time(created)
  for file in files {
    if file.0.has_suffix(".db") || file.0.has_suffix(".files") {
      let signature = key.detached(file.1[:], created=time) catch {
        err => raise Invalid(file=file.0 + ".sig", message="\{err}")
      }
      result.push((file.0 + ".sig", signature))
    }
  }
  for file in files {
    if file.0.has_suffix(".db.tar.gz") || file.0.has_suffix(".files.tar.gz") {
      let signature = key.detached(file.1[:], created=time) catch {
        err => raise Invalid(file=file.0 + ".sig", message="\{err}")
      }
      result.push((file.0 + ".sig", signature))
    }
  }
  result
}

///|
/// The `(directory, file name, content)` of every entry of a database tar.
fn arch_database_entries(
  name : String,
  data : Bytes,
) -> Array[(String, String)] raise RepoError {
  let members = @compress.gzip_members(data[:], max_size=1 << 28) catch {
    err => raise Invalid(file=name, message="\{err}")
  }
  if members.length() != 1 {
    raise Invalid(file=name, message="expected one gzip stream")
  }
  let entries = @tar.parse(members[0].1) catch {
    err => raise Invalid(file=name, message="\{err}")
  }
  let result : Array[(String, String)] = []
  for entry in entries {
    if entry.kind is File(content) {
      result.push((entry.path, @utf8.decode_lossy(content[:])))
    }
  }
  result
}

///|
/// Check a pacman repository (as made by `arch_index`, signed or not) against
/// the packages: both databases and their `.db` / `.files` copies are there,
/// every package has its `desc` (and the `files` list) with the right file name,
/// sizes and checksums, and no other package is listed. Returns the problems found.
pub fn check_arch(
  files : Array[(String, Bytes)],
  packages : Array[PackageFile],
  signatures : Array[PackageFile],
  name~ : String,
) -> Array[String] {
  let problems : Array[String] = []
  let expected : Array[(String, String, String)] = []
  for file in packages {
    try {
      let pkg = arch_read(file)
      let signature = find_package_file(signatures, file.name + ".sig")
      let (dir, text) = arch_desc(file, pkg, signature)
      let parts = text.split("\u{0}").map(p => p.to_owned()).collect()
      expected.push((dir, parts[0], parts[1]))
    } catch {
      err => problems.push("\{err}")
    }
  }
  for suffix in ["db", "files"] {
    match
      (
        find_file(files, "\{name}.\{suffix}.tar.gz"),
        find_file(files, "\{name}.\{suffix}"),
      ) {
      (Some(real), Some(copy)) => {
        if real != copy {
          problems.push(
            "\{name}.\{suffix} is not a copy of \{name}.\{suffix}.tar.gz",
          )
        }
        try {
          let entries = arch_database_entries("\{name}.\{suffix}.tar.gz", real)
          let descs = entries.filter(e => e.0.has_suffix("/desc"))
          if descs.length() != expected.length() {
            problems.push(
              "\{name}.\{suffix}.tar.gz: lists \{descs.length()} packages, expected \{expected.length()}",
            )
          }
          for item in expected {
            if !entries.contains((item.0 + "/desc", item.1)) {
              problems.push(
                "\{name}.\{suffix}.tar.gz: the desc of \{item.0} is missing or wrong",
              )
            }
            if suffix == "files" &&
              !entries.contains((item.0 + "/files", item.2)) {
              problems.push(
                "\{name}.\{suffix}.tar.gz: the file list of \{item.0} is missing or wrong",
              )
            }
          }
        } catch {
          err => problems.push("\{err}")
        }
      }
      _ =>
        problems.push(
          "\{name}.\{suffix}.tar.gz or \{name}.\{suffix} is missing",
        )
    }
  }
  problems
}

///|
/// Check the signatures of a pacman repository: `<name>.db.sig`,
/// `<name>.db.tar.gz.sig`, `<name>.files.sig` and `<name>.files.tar.gz.sig`
/// must all be there and match the files, for a key of `ring`. Returns the
/// problems found.
pub fn check_arch_signature(
  files : Array[(String, Bytes)],
  ring : @sign.PublicKeyring,
  name~ : String,
) -> Array[String] {
  let problems : Array[String] = []
  for
    target in [
      "\{name}.db",
      "\{name}.db.tar.gz",
      "\{name}.files",
      "\{name}.files.tar.gz",
    ] {
    match (find_file(files, target), find_file(files, target + ".sig")) {
      (Some(data), Some(signature)) =>
        try ring.verify_detached(data[:], signature) catch {
          err => problems.push("\{target}.sig: \{err}")
        } noraise {
          _ => ()
        }
      (None, _) => problems.push("\{target}: missing")
      (_, None) => problems.push("\{target}.sig: missing")
    }
  }
  problems
}

///|
/// The build time recorded in an Arch Linux package (seconds since the
/// epoch), used as a reproducible default date for a repository.
pub fn arch_time(file : PackageFile) -> Int64 raise RepoError {
  let pkg = arch_read(file)
  match pkg.field("builddate") {
    Some(text) => @string.parse_int64(text[:]) catch { _ => 0L }
    None => 0L
  }
}
