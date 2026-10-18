///|
/// Parsed command line of one command: positional arguments, options that
/// take a value, and boolean flags.
priv struct Options {
  positional : Array[String]
  values : Map[String, String]
  flags : Map[String, Bool]
}

///|
/// Split `args` into positional arguments and options. `value_options` maps
/// every accepted spelling (`-o`, `--out`) to the canonical name; `flag_options`
/// does the same for options without a value. `--name=value` is accepted for
/// value options.
fn parse_options(
  args : Array[String],
  value_options : Map[String, String],
  flag_options : Map[String, String],
) -> Options raise CliError {
  let options : Options = { positional: [], values: Map([]), flags: Map([]), }
  let mut i = 0
  let mut only_positional = false
  while i < args.length() {
    let arg = args[i]
    i += 1
    if only_positional || arg == "-" || !arg.has_prefix("-") {
      options.positional.push(arg)
      continue
    }
    if arg == "--" {
      only_positional = true
      continue
    }
    let (name, inline_value) = match arg.find("=") {
      Some(at) if arg.has_prefix("--") =>
        (arg[0:at].to_owned(), Some(arg[at + 1:].to_owned()))
      _ => (arg, None)
    }
    match value_options.get(name) {
      Some(canonical) => {
        let value = match inline_value {
          Some(v) => v
          None => {
            if i >= args.length() {
              raise Usage("option \"\{name}\" needs a value")
            }
            i += 1
            args[i - 1]
          }
        }
        options.values[canonical] = value
      }
      None =>
        match flag_options.get(name) {
          Some(canonical) if inline_value is None =>
            options.flags[canonical] = true
          _ => raise Usage("unknown option \"\{arg}\"")
        }
    }
  }
  options
}

///|
fn Options::flag(self : Options, name : String) -> Bool {
  self.flags.get(name).unwrap_or(false)
}

///|
fn Options::value(self : Options, name : String) -> String? {
  self.values.get(name)
}
