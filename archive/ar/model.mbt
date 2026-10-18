///|
/// One file stored in an ar archive.
///
/// `mtime` is in seconds since the Unix epoch and `mode` holds the file mode
/// including the file type bits (`0o100644` for a regular file).
pub(all) struct Member {
  name : String
  data : Bytes
  mtime : Int64
  uid : Int32
  gid : Int32
  mode : Int32
} derive(Eq, Debug)

///|
/// A regular file member. Defaults to modification time 0, owner 0:0 and
/// mode `0100644`, which is what deterministic deb builds use.
pub fn Member::new(
  name : String,
  data : Bytes,
  mtime~ : Int64 = 0L,
  uid~ : Int32 = 0,
  gid~ : Int32 = 0,
  mode~ : Int32 = 0o100644,
) -> Member {
  { name, data, mtime, uid, gid, mode, }
}
