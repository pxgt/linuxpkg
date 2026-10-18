///|
/// A cpio archive could not be written or read.
///
/// - `Invalid`: an entry cannot be represented (value too large, bad name).
/// - `Corrupt`: the archive is malformed; `offset` is the byte position of the
///   offending header.
pub(all) suberror CpioError {
  Invalid(field~ : String, message~ : String)
  Corrupt(offset~ : Int32, message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for CpioError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(offset~, message~) =>
      logger.write_string("corrupt cpio at offset \{offset}: \{message}")
  }
}
