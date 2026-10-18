///|
fn cmd_verify(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(args, Map([]), Map([]))
  let path = match options.positional {
    [path] => path
    [] => raise Usage("verify needs the path of a .deb or .rpm file")
    _ => raise Usage("verify takes exactly one package file")
  }
  let pkg = load_package(path)
  let problems = pkg.problems()
  if problems.length() > 0 {
    for problem in problems {
      eprintln("\{path}: \{problem}")
    }
    raise Mismatch(
      "\{path}: verification failed (\{problems.length()} problem(s))",
    )
  }
  println("\{path}: OK (\{pkg.checked_files()} checksums verified)")
  0
}
