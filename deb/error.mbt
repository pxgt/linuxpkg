///|
/// A deb could not be built, read or verified.
///
/// - `Invalid` means the package description cannot be turned into a deb;
///   `field` names the offending input.
/// - `Corrupt` means a file that should be a deb is malformed.
/// - `Unsupported` means the deb is valid but uses something this package
///   does not implement, such as bzip2 compression.
pub(all) suberror DebError {
  Invalid(field~ : String, message~ : String)
  Corrupt(message~ : String)
  Unsupported(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for DebError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(message~) => logger.write_string("corrupt deb: \{message}")
    Unsupported(message~) => logger.write_string("unsupported deb: \{message}")
  }
}
