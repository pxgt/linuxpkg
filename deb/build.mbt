///|
/// An entry of the data archive together with the key it is sorted by.
priv struct Node {
  key : Bytes
  entry : @tar.Entry
}

///|
/// `/usr/bin/hello` becomes `./usr/bin/hello`.
fn tar_path(path : String) -> String {
  "." + path
}

///|
/// All proper ancestors of an absolute path, outermost first:
/// `/usr/bin/hello` gives `/usr` and `/usr/bin`.
fn parent_dirs(path : String) -> Array[String] {
  let dirs : Array[String] = []
  for i in 1..<path.length() {
    if path[i] == '/' {
      dirs.push(path[0:i].to_owned())
    }
  }
  dirs
}

///|
fn to_tar_entry(entry : @spec.Entry, default_mtime : Int64) -> @tar.Entry {
  let path = tar_path(entry.path)
  let mtime = match entry.mtime {
    Some(t) => t
    None => default_mtime
  }
  match entry.kind {
    File(content) =>
      @tar.Entry::file(
        path,
        content,
        mode=entry.mode,
        uname=entry.owner,
        gname=entry.group,
        mtime~,
      )
    Dir =>
      @tar.Entry::dir(
        path,
        mode=entry.mode,
        uname=entry.owner,
        gname=entry.group,
        mtime~,
      )
    Symlink(target) =>
      @tar.Entry::symlink(
        path,
        target,
        uname=entry.owner,
        gname=entry.group,
        mtime~,
      )
  }
}

///|
/// The data archive contents, sorted by path with every parent directory
/// present, plus the `md5sums` lines for the regular files.
fn data_entries(
  spec : @spec.PackageSpec,
) -> (Array[@tar.Entry], Array[(Bytes, String)]) {
  let present : Map[String, Bool] = Map([])
  for entry in spec.entries {
    present[entry.path] = true
  }
  let nodes : Array[Node] = [
    { key: b"", entry: @tar.Entry::dir("./", mtime=spec.mtime), },
  ]
  let sums : Array[(Bytes, String)] = []
  for entry in spec.entries {
    for dir in parent_dirs(entry.path) {
      if !present.contains(dir) {
        present[dir] = true
        nodes.push({
          key: @utf8.encode(dir),
          entry: @tar.Entry::dir(tar_path(dir), mtime=spec.mtime),
        })
      }
    }
  }
  for entry in spec.entries {
    let key = @utf8.encode(entry.path)
    nodes.push({ key, entry: to_tar_entry(entry, spec.mtime), })
    match entry.kind {
      File(content) =>
        sums.push((key, "\{md5_hex(content)}  \{entry.path[1:]}\n"))
      _ => ()
    }
  }
  nodes.sort_by((a, b) => compare_bytes(a.key, b.key))
  sums.sort_by((a, b) => compare_bytes(a.0, b.0))
  (nodes.map(n => n.entry), sums)
}

///|
fn conffiles_text(spec : @spec.PackageSpec) -> String? {
  let paths : Array[String] = []
  for entry in spec.entries {
    if entry.config {
      paths.push(entry.path)
    }
  }
  if paths.length() == 0 {
    return None
  }
  paths.sort_by((a, b) => compare_bytes(@utf8.encode(a), @utf8.encode(b)))
  Some(paths.map(p => "\{p}\n").join(""))
}

///|
fn script_member(
  name : String,
  field : String,
  script : String?,
  mtime : Int64,
  out : Array[@tar.Entry],
) -> Unit raise DebError {
  match script {
    None => ()
    Some(text) => {
      if !text.has_prefix("#!") {
        raise DebError::Invalid(
          field~,
          message="must start with a #! line naming its interpreter",
        )
      }
      out.push(
        @tar.Entry::file("./\{name}", @utf8.encode(text), mode=0o755, mtime~),
      )
    }
  }
}

///|
fn control_entries(
  spec : @spec.PackageSpec,
  md5sums : String,
) -> Array[@tar.Entry] raise DebError {
  let mtime = spec.mtime
  let entries : Array[@tar.Entry] = [@tar.Entry::dir("./", mtime~)]
  match conffiles_text(spec) {
    Some(text) =>
      entries.push(@tar.Entry::file("./conffiles", @utf8.encode(text), mtime~))
    None => ()
  }
  entries.push(
    @tar.Entry::file("./control", @utf8.encode(control_file(spec)), mtime~),
  )
  if md5sums.length() > 0 {
    entries.push(@tar.Entry::file("./md5sums", @utf8.encode(md5sums), mtime~))
  }
  // Alphabetical, like dpkg-deb: postinst, postrm, preinst, prerm.
  script_member(
    "postinst",
    "scripts.post_install",
    spec.scripts.post_install,
    mtime,
    entries,
  )
  script_member(
    "postrm",
    "scripts.post_remove",
    spec.scripts.post_remove,
    mtime,
    entries,
  )
  script_member(
    "preinst",
    "scripts.pre_install",
    spec.scripts.pre_install,
    mtime,
    entries,
  )
  script_member(
    "prerm",
    "scripts.pre_remove",
    spec.scripts.pre_remove,
    mtime,
    entries,
  )
  entries
}

///|
fn tar_gz(entries : Array[@tar.Entry], what : String) -> Bytes raise DebError {
  let tar = @tar.build(entries, long_names=Gnu) catch {
    err => raise DebError::Invalid(field=what, message="\{err}")
  }
  @gzip.compress(tar)
}

///|
/// Build a `.deb` file from a package description.
///
/// The result is an ar archive holding `debian-binary`, `control.tar.gz` and
/// `data.tar.gz`, in that order. It depends only on `spec`: the same spec
/// always yields the same bytes. Files are owned by the user and group named
/// in the entry; ids are always 0 and package managers resolve the names.
pub fn build(spec : @spec.PackageSpec) -> Bytes raise DebError {
  spec.validate() catch {
    @spec.SpecError::Invalid(field~, message~) =>
      raise DebError::Invalid(field~, message~)
  }
  let (data, sums) = data_entries(spec)
  let md5sums = sums.map(s => s.1).join("")
  let control = tar_gz(control_entries(spec, md5sums), "control.tar")
  let data_tar = tar_gz(data, "data.tar")
  let mtime = spec.mtime
  @ar.build([
    @ar.Member::new("debian-binary", b"2.0\n", mtime~),
    @ar.Member::new("control.tar.gz", control, mtime~),
    @ar.Member::new("data.tar.gz", data_tar, mtime~),
  ]) catch {
    err => raise DebError::Invalid(field="deb", message="\{err}")
  }
}

///|
/// Lexicographic comparison of byte strings (C locale `sort` order).
fn compare_bytes(a : Bytes, b : Bytes) -> Int32 {
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<shared {
    if a[i] != b[i] {
      return a[i].to_int() - b[i].to_int()
    }
  }
  a.length() - b.length()
}
