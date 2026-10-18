///|
/// How names that do not fit a ustar header are stored.
pub(all) enum LongNames {
  /// POSIX PAX extended headers (`x`). Understood by GNU tar, libarchive and
  /// Python, but not by the extractor inside `dpkg`.
  Pax
  /// GNU `L`/`K` pseudo entries, which is what `dpkg-deb` itself produces.
  Gnu
} derive(Eq, Debug)

///|
/// What a tar entry stores.
pub(all) enum EntryKind {
  /// A regular file with its full content.
  File(Bytes)
  /// A directory.
  Dir
  /// A symbolic link pointing at the given target.
  Symlink(String)
} derive(Eq, Debug)

///|
/// One member of a tar archive.
///
/// `path` is written exactly as given (conventionally `./usr/bin/hello`);
/// directories get a trailing `/` added when it is missing. `mtime` is in
/// seconds since the Unix epoch.
pub(all) struct Entry {
  path : String
  kind : EntryKind
  mode : Int32
  uid : Int32
  gid : Int32
  uname : String
  gname : String
  mtime : Int64
} derive(Eq, Debug)

///|
/// A regular file. Defaults to mode `0644`, owner `root:root` (ids 0) and
/// modification time 0.
pub fn Entry::file(
  path : String,
  content : Bytes,
  mode~ : Int32 = 0o644,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  uname~ : String = "root",
  gname~ : String = "root",
  mtime~ : Int64 = 0L,
) -> Entry {
  { path, kind: File(content), mode, uid, gid, uname, gname, mtime, }
}

///|
/// A directory. Defaults to mode `0755`, owner `root:root` and modification
/// time 0.
pub fn Entry::dir(
  path : String,
  mode~ : Int32 = 0o755,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  uname~ : String = "root",
  gname~ : String = "root",
  mtime~ : Int64 = 0L,
) -> Entry {
  { path, kind: Dir, mode, uid, gid, uname, gname, mtime, }
}

///|
/// A symbolic link at `path` pointing to `target`. Its mode is `0777`.
pub fn Entry::symlink(
  path : String,
  target : String,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  uname~ : String = "root",
  gname~ : String = "root",
  mtime~ : Int64 = 0L,
) -> Entry {
  { path, kind: Symlink(target), mode: 0o777, uid, gid, uname, gname, mtime, }
}
