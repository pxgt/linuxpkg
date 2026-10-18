///|
fn options_of(args : Array[String]) -> Options raise CliError {
  parse_options(
    args,
    { "--format": "format", "-f": "format", "--out": "out", "-o": "out" },
    { "--force": "force" },
  )
}

///|
fn options_error(args : Array[String]) -> String {
  try options_of(args) catch {
    Usage(message) => "usage: \{message}"
    Failed(message) => "failed: \{message}"
  } noraise {
    _ => "ok"
  }
}

///|
test "positional arguments and options are separated" {
  let options = options_of([
    "cfg.json", "--format", "deb", "-o", "dist", "--force", "extra",
  ])
  assert_eq(options.positional, ["cfg.json", "extra"])
  assert_eq(options.value("format"), Some("deb"))
  assert_eq(options.value("out"), Some("dist"))
  assert_eq(options.value("missing"), None)
  assert_true(options.flag("force"))
  assert_true(!options.flag("other"))
}

///|
test "options accept the name=value form" {
  let options = options_of(["--out=build/out", "--format=all", "cfg.json"])
  assert_eq(options.value("out"), Some("build/out"))
  assert_eq(options.value("format"), Some("all"))
  assert_eq(options.positional, ["cfg.json"])
}

///|
test "a dash alone and everything after -- is positional" {
  let options = options_of(["-", "--", "--force", "-o"])
  assert_eq(options.positional, ["-", "--force", "-o"])
  assert_true(!options.flag("force"))
}

///|
test "bad options are usage errors" {
  inspect(
    options_error(["--bogus"]),
    content="usage: unknown option \"--bogus\"",
  )
  inspect(
    options_error(["--out"]),
    content="usage: option \"--out\" needs a value",
  )
  inspect(
    options_error(["--force=yes"]),
    content="usage: unknown option \"--force=yes\"",
  )
  inspect(options_error(["-x"]), content="usage: unknown option \"-x\"")
}

///|
test "path helpers" {
  assert_eq(dirname("a/b/c.json"), "a/b")
  assert_eq(dirname("c.json"), "")
  assert_eq(dirname("/c.json"), "/")
  assert_eq(dirname("C:\\work\\c.json"), "C:\\work")
  assert_true(is_absolute("/etc/x"))
  assert_true(is_absolute("C:\\x"))
  assert_true(is_absolute("d:/x"))
  assert_true(!is_absolute("x/y"))
  assert_true(!is_absolute("1:/x"))
  assert_eq(join_path("", "x/y"), "x/y")
  assert_eq(join_path("a/b", "x"), "a/b/x")
  assert_eq(join_path("a/b/", "x"), "a/b/x")
  assert_eq(join_path("a/b", "/abs/x"), "/abs/x")
}

///|
test "exit codes of the front end" {
  assert_eq(run(["--version"]), 0)
  assert_eq(run(["-V"]), 0)
  assert_eq(run(["--help"]), 0)
  assert_eq(run([]), 1)
  assert_eq(run(["bogus"]), 1)
  assert_eq(run(["build"]), 1)
  assert_eq(run(["build", "a.json", "b.json"]), 1)
  assert_eq(run(["build", "a.json", "--format", "zip"]), 1)
  assert_eq(run(["build", "does-not-exist.json"]), 1)
  assert_eq(run(["init", "a", "b"]), 1)
}
