///|
/// An Alpine Linux package could not be built, read or verified.
///
/// - `Invalid`: the package description cannot be turned into an Arch
///   package; `field` names the offending input.
/// - `Corrupt`: a file that should be a package is malformed.
/// - `Unsupported`: the package is valid but uses something this package
///   does not implement, such as an unknown signature scheme.
pub(all) suberror ApkError {
  Invalid(field~ : String, message~ : String)
  Corrupt(message~ : String)
  Unsupported(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for ApkError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
    Corrupt(message~) => logger.write_string("corrupt apk: \{message}")
    Unsupported(message~) => logger.write_string("unsupported apk: \{message}")
  }
}
