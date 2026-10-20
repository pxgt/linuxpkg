///|
/// A repository index could not be built.
///
/// `file` is the package file (or index file) that caused the problem.
pub(all) suberror RepoError {
  Invalid(file~ : String, message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for RepoError with fn output(self, logger) {
  match self {
    Invalid(file~, message~) => logger.write_string("\{file}: \{message}")
  }
}

///|
/// A package file by name and content.
pub(all) struct PackageFile {
  /// File name without a directory, for example `hello_1.0.0-1_all.deb`.
  name : String
  data : Bytes
} derive(Eq, Debug)
