///|
/// What an install-tree entry is.
pub(all) enum EntryKind {
  /// A regular file with its full content.
  File(Bytes)
  /// A directory.
  Dir
  /// A symbolic link pointing at the given target.
  Symlink(String)
} derive(Eq, Debug)

///|
/// One item of the installed file tree.
///
/// `mtime` overrides the package-wide modification time for this entry.
/// `config` marks a configuration file (`conffiles` in deb, `%config` in
/// rpm) that package managers must not overwrite silently on upgrade.
pub(all) struct Entry {
  path : String
  kind : EntryKind
  mode : Int32
  owner : String
  group : String
  mtime : Int64?
  config : Bool
} derive(Eq, Debug)

///|
/// A regular file. Defaults to mode `0644`, owner and group `root`.
pub fn Entry::file(
  path : String,
  content : Bytes,
  mode~ : Int32 = 0o644,
  owner~ : String = "root",
  group~ : String = "root",
  mtime? : Int64,
  config~ : Bool = false,
) -> Entry {
  { path, kind: File(content), mode, owner, group, mtime, config, }
}

///|
/// A directory. Defaults to mode `0755`, owner and group `root`.
pub fn Entry::dir(
  path : String,
  mode~ : Int32 = 0o755,
  owner~ : String = "root",
  group~ : String = "root",
  mtime? : Int64,
) -> Entry {
  { path, kind: Dir, mode, owner, group, mtime, config: false, }
}

///|
/// A symbolic link at `path` pointing to `target`. Its mode is always `0777`.
pub fn Entry::symlink(
  path : String,
  target : String,
  owner~ : String = "root",
  group~ : String = "root",
  mtime? : Int64,
) -> Entry {
  {
    path,
    kind: Symlink(target),
    mode: 0o777,
    owner,
    group,
    mtime,
    config: false,
  }
}

///|
/// Comparison operators of a versioned relation such as `libc6 (>= 2.31)`.
pub(all) enum VersionOp {
  Lt
  Le
  Eq
  Ge
  Gt
} derive(Eq, Debug)

///|
/// A relation to another package (`Depends`, `Conflicts`, `Provides`, ...),
/// optionally restricted to a version range.
pub(all) struct Dependency {
  name : String
  constraint : (VersionOp, String)?
} derive(Eq, Debug)

///|
/// Maintainer scripts. Each field holds the script text, shebang included.
pub(all) struct Scripts {
  pre_install : String?
  post_install : String?
  pre_remove : String?
  post_remove : String?
} derive(Eq, Debug)

///|
/// No maintainer scripts.
pub fn Scripts::empty() -> Scripts {
  {
    pre_install: None,
    post_install: None,
    pre_remove: None,
    post_remove: None,
  }
}

///|
/// Everything needed to build a deb or an rpm.
///
/// The file tree is held in memory (`entries`), so the model does not touch
/// the file system and works on every backend. `mtime` is the default
/// modification time (seconds since the Unix epoch) of all entries and of the
/// build itself; fixing it is what makes builds reproducible.
pub(all) struct PackageSpec {
  name : String
  version : String
  release : String
  epoch : Int32
  arch : Arch
  maintainer : String
  description : String
  homepage : String?
  license : String?
  vendor : String?
  section : String
  priority : String
  depends : Array[Dependency]
  recommends : Array[Dependency]
  suggests : Array[Dependency]
  conflicts : Array[Dependency]
  replaces : Array[Dependency]
  provides : Array[Dependency]
  entries : Array[Entry]
  scripts : Scripts
  mtime : Int64
} derive(Eq, Debug)

///|
/// Create a package description. Only the identity of the package is
/// required; everything else has a sensible default. The result is not
/// validated, call `PackageSpec::validate` before building.
pub fn PackageSpec::new(
  name~ : String,
  version~ : String,
  arch~ : Arch,
  maintainer~ : String,
  description~ : String,
  release~ : String = "1",
  epoch~ : Int32 = 0,
  homepage? : String,
  license? : String,
  vendor? : String,
  section~ : String = "misc",
  priority~ : String = "optional",
  depends~ : Array[Dependency] = [],
  recommends~ : Array[Dependency] = [],
  suggests~ : Array[Dependency] = [],
  conflicts~ : Array[Dependency] = [],
  replaces~ : Array[Dependency] = [],
  provides~ : Array[Dependency] = [],
  entries~ : Array[Entry] = [],
  scripts~ : Scripts = Scripts::empty(),
  mtime~ : Int64 = 0L,
) -> PackageSpec {
  {
    name,
    version,
    release,
    epoch,
    arch,
    maintainer,
    description,
    homepage,
    license,
    vendor,
    section,
    priority,
    depends,
    recommends,
    suggests,
    conflicts,
    replaces,
    provides,
    entries,
    scripts,
    mtime,
  }
}
