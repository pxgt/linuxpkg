///|
/// A tar archive could not be written or read.
///
/// - `Invalid` means the caller handed over something that cannot be
///   represented (an empty path, a number that does not fit its field).
/// - `Corrupt` means an archive is malformed; `offset` is the byte position of
///   the offending header or record.
/// - `Unsupported` means the archive is valid but uses a feature this package
///   does not implement.
pub(all) suberror TarError {
  Invalid(field~ : String, message~ : String)
  Corrupt(offset~ : Int32, message~ : String)
  Unsupported(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for TarError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(offset~, message~) =>
      logger.write_string("corrupt tar at offset \{offset}: \{message}")
    Unsupported(message~) => logger.write_string("unsupported tar: \{message}")
  }
}
