///|
/// An Arch Linux package could not be built, read or verified.
///
/// - `Invalid`: the package description cannot be turned into an Arch
///   package; `field` names the offending input.
/// - `Corrupt`: a file that should be a package is malformed.
/// - `Unsupported`: the package is valid but uses something this package
///   does not implement, such as bzip2 compression.
pub(all) suberror ArchError {
  Invalid(field~ : String, message~ : String)
  Corrupt(message~ : String)
  Unsupported(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for ArchError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(message~) => logger.write_string("corrupt package: \{message}")
    Unsupported(message~) =>
      logger.write_string("unsupported package: \{message}")
  }
}
