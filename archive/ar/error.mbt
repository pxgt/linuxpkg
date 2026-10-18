///|
/// An ar archive could not be written or read.
///
/// - `Invalid` means a member cannot be represented (a name that is too long,
///   a number that does not fit its field).
/// - `Corrupt` means the archive is malformed; `offset` is the byte position
///   of the offending member header.
pub(all) suberror ArError {
  Invalid(field~ : String, message~ : String)
  Corrupt(offset~ : Int32, message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for ArError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(offset~, message~) =>
      logger.write_string("corrupt ar at offset \{offset}: \{message}")
  }
}
