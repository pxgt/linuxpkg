///|
/// One member of a cpio archive in the "new ASCII" (`newc`, magic `070701`)
/// format.
///
/// `mode` is the complete `st_mode` including the file type bits
/// (`0o100644` regular file, `0o040755` directory, `0o120777` symlink; a
/// symlink stores its target as `data`). All numbers must fit 32 bits.
pub(all) struct Entry {
  path : String
  data : Bytes
  mode : Int32
  uid : Int32
  gid : Int32
  nlink : Int32
  mtime : Int64
  ino : Int32
  dev_major : Int32
  dev_minor : Int32
  rdev_major : Int32
  rdev_minor : Int32
} derive(Eq, Debug)

///|
/// A regular file. Defaults: mode `0100644`, owner 0:0, one link, mtime 0,
/// inode 0.
pub fn Entry::file(
  path : String,
  data : Bytes,
  mode~ : Int32 = 0o100644,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  mtime~ : Int64 = 0L,
  ino~ : Int32 = 0,
) -> Entry {
  {
    path,
    data,
    mode,
    uid,
    gid,
    nlink: 1,
    mtime,
    ino,
    dev_major: 0,
    dev_minor: 0,
    rdev_major: 0,
    rdev_minor: 0,
  }
}

///|
/// A directory (mode `040755` by default, two links).
pub fn Entry::dir(
  path : String,
  mode~ : Int32 = 0o040755,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  mtime~ : Int64 = 0L,
  ino~ : Int32 = 0,
) -> Entry {
  { ..Entry::file(path, b"", mode~, uid~, gid~, mtime~, ino~), nlink: 2, }
}

///|
/// A symbolic link; the target is the entry data.
pub fn Entry::symlink(
  path : String,
  target : String,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  mtime~ : Int64 = 0L,
  ino~ : Int32 = 0,
) -> Entry {
  Entry::file(
    path,
    @utf8.encode(target),
    mode=0o120777,
    uid~,
    gid~,
    mtime~,
    ino~,
  )
}
