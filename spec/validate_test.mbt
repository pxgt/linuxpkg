///|
/// Run a validator and describe the outcome: "ok" or the error message.
fn outcome(check : () -> Unit raise @spec.SpecError) -> String {
  try check() catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "package names" {
  inspect(outcome(() => @spec.validate_package_name("hello")), content="ok")
  inspect(outcome(() => @spec.validate_package_name("g++")), content="ok")
  inspect(
    outcome(() => @spec.validate_package_name("libfoo2.1-dev")),
    content="ok",
  )
  inspect(outcome(() => @spec.validate_package_name("9to5")), content="ok")
  inspect(
    outcome(() => @spec.validate_package_name("a")),
    content="name: must be at least two characters long",
  )
  inspect(
    outcome(() => @spec.validate_package_name("")),
    content="name: must be at least two characters long",
  )
  inspect(
    outcome(() => @spec.validate_package_name("Hello")),
    content="name: must be lowercase",
  )
  inspect(
    outcome(() => @spec.validate_package_name("-hello")),
    content="name: must start with a letter or a digit",
  )
  inspect(
    outcome(() => @spec.validate_package_name("hello_world")),
    content="name: contains \"_\", only letters, digits, '+', '-' and '.' are allowed",
  )
  inspect(
    outcome(() => @spec.validate_package_name("hello world")),
    content="name: contains \" \", only letters, digits, '+', '-' and '.' are allowed",
  )
  inspect(
    outcome(() => @spec.validate_package_name("a".repeat(129))),
    content="name: must be at most 128 characters long",
  )
}

///|
test "versions" {
  inspect(outcome(() => @spec.validate_version("1")), content="ok")
  inspect(outcome(() => @spec.validate_version("1.2.3")), content="ok")
  inspect(outcome(() => @spec.validate_version("2.0~rc1")), content="ok")
  inspect(
    outcome(() => @spec.validate_version("1.0+git20240101")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_version("")),
    content="version: must not be empty",
  )
  inspect(
    outcome(() => @spec.validate_version("v1.0")),
    content="version: must start with a digit",
  )
  inspect(
    outcome(() => @spec.validate_version("1.0-rc1")),
    content="version: contains \"-\", only letters, digits, '.', '+' and '~' are allowed (use '~' for pre-releases such as 1.0~rc1)",
  )
  inspect(
    outcome(() => @spec.validate_version("1:2.0")),
    content="version: contains \":\", only letters, digits, '.', '+' and '~' are allowed (use '~' for pre-releases such as 1.0~rc1)",
  )
}

///|
test "releases" {
  inspect(outcome(() => @spec.validate_release("1")), content="ok")
  inspect(outcome(() => @spec.validate_release("0ubuntu2")), content="ok")
  inspect(outcome(() => @spec.validate_release("rc1.el9")), content="ok")
  inspect(
    outcome(() => @spec.validate_release("")),
    content="release: must not be empty",
  )
  inspect(
    outcome(() => @spec.validate_release("1 2")),
    content="release: contains \" \", only letters, digits, '.', '+' and '~' are allowed (use '~' for pre-releases such as 1.0~rc1)",
  )
}

///|
test "install paths" {
  inspect(
    outcome(() => @spec.validate_install_path("/usr/bin/hello", field="dst")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/etc", field="dst")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/opt/my app/x y", field="dst")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_install_path("", field="dst")),
    content="dst: must not be empty",
  )
  inspect(
    outcome(() => @spec.validate_install_path("usr/bin", field="dst")),
    content="dst: must be an absolute path starting with '/'",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/", field="dst")),
    content="dst: must not be the root directory",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/usr/bin/", field="dst")),
    content="dst: must not end with '/'",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/usr//bin", field="dst")),
    content="dst: must not contain empty segments (\"//\")",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/usr/../etc", field="dst")),
    content="dst: must not contain \"..\"",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/usr/./bin", field="dst")),
    content="dst: must not contain \".\"",
  )
  inspect(
    outcome(() => @spec.validate_install_path("/usr/bin\n/x", field="dst")),
    content="dst: must not contain control characters",
  )
  inspect(
    outcome(() => {
      @spec.validate_install_path("/a" + "b".repeat(4100), field="dst")
    }),
    content="dst: must be at most 4096 characters long",
  )
}

///|
test "link targets" {
  inspect(
    outcome(() => @spec.validate_link_target("../lib/libfoo.so.1", field="src")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_link_target("hello", field="src")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_link_target("", field="src")),
    content="src: must not be empty",
  )
  inspect(
    outcome(() => @spec.validate_link_target("a\u{0}b", field="src")),
    content="src: must not contain control characters",
  )
}

///|
test "modes" {
  inspect(outcome(() => @spec.validate_mode(0o644, field="mode")), content="ok")
  inspect(
    outcome(() => @spec.validate_mode(0o4755, field="mode")),
    content="ok",
  )
  inspect(outcome(() => @spec.validate_mode(0, field="mode")), content="ok")
  inspect(
    outcome(() => @spec.validate_mode(-1, field="mode")),
    content="mode: must be between 0 and 07777 (octal), got -1",
  )
  inspect(
    outcome(() => @spec.validate_mode(0o10000, field="mode")),
    content="mode: must be between 0 and 07777 (octal), got 10000",
  )
}

///|
test "account names" {
  inspect(
    outcome(() => @spec.validate_account("www-data", field="owner")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_account("_apt", field="owner")),
    content="ok",
  )
  inspect(
    outcome(() => @spec.validate_account("", field="owner")),
    content="owner: must be 1 to 32 characters long",
  )
  inspect(
    outcome(() => @spec.validate_account("a".repeat(33), field="group")),
    content="group: must be 1 to 32 characters long",
  )
  inspect(
    outcome(() => @spec.validate_account("root:x", field="owner")),
    content="owner: contains \":\", only letters, digits, '_', '-' and '.' are allowed",
  )
}
