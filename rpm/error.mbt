///|
/// An rpm could not be built, read or verified.
///
/// - `Invalid`: the package description cannot be turned into an rpm.
/// - `Corrupt`: a file that should be an rpm is malformed; `offset` is the
///   byte position of the problem (or -1 when it has no single position).
/// - `Unsupported`: the rpm is valid but uses something this package does not
///   implement, such as zstd or xz compression.
pub(all) suberror RpmError {
  Invalid(field~ : String, message~ : String)
  Corrupt(offset~ : Int32, message~ : String)
  Unsupported(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for RpmError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(offset~, message~) =>
      if offset < 0 {
        logger.write_string("corrupt rpm: \{message}")
      } else {
        logger.write_string("corrupt rpm at offset \{offset}: \{message}")
      }
    Unsupported(message~) => logger.write_string("unsupported rpm: \{message}")
  }
}
