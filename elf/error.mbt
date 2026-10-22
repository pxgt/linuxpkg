///|
/// Why a file could not be read as an ELF object.
///
/// - `NotElf`: the file does not start with the ELF magic number.
/// - `Truncated`: the file ends before a part the header points to; the text
///   names that part.
/// - `Invalid`: a field has a value that cannot be right (or is unsupported).
pub(all) suberror ElfError {
  NotElf
  Truncated(String)
  Invalid(String)
} derive(Eq, Debug)

///|
pub impl Show for ElfError with fn output(self, logger) {
  match self {
    NotElf => logger.write_string("not an ELF file")
    Truncated(what) => logger.write_string("ELF file is cut off in the \{what}")
    Invalid(message) => logger.write_string("invalid ELF file: \{message}")
  }
}
