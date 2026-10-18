///|
/// A problem found while validating a package description. `field` names the
/// offending input (for example `name` or `contents[2].dst`) and `message`
/// explains what is wrong with it.
pub(all) suberror SpecError {
  Invalid(field~ : String, message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for SpecError with fn output(self, logger) {
  match self {
    Invalid(field~, message~) => logger.write_string("\{field}: \{message}")
  }
}

///|
fn invalid(field : String, message : String) -> SpecError {
  SpecError::Invalid(field~, message~)
}
