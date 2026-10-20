///|
/// Why a compressed stream could not be handled.
///
/// - `Corrupt`: the stream is damaged or truncated; the text names the format.
/// - `TooLarge`: the stream would unpack to more than the allowed number of
///   bytes (the argument is that limit).
/// - `Unsupported`: the stream is well formed but uses a feature this library
///   lacks.
pub(all) suberror CompressError {
  Corrupt(String)
  TooLarge(Int32)
  Unsupported(String)
} derive(Eq, Debug)

///|
pub impl Show for CompressError with fn output(self, logger) {
  match self {
    Corrupt(message) => logger.write_string(message)
    TooLarge(limit) =>
      logger.write_string("the data unpacks to more than \{limit} bytes")
    Unsupported(message) => logger.write_string(message)
  }
}
