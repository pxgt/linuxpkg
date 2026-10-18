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
    Mismatch(message) => "mismatch: \{message}"
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

///|
test "permission strings look like ls -l" {
  assert_eq(mode_string("file", "0644"), "-rw-r--r--")
  assert_eq(mode_string("file", "0755"), "-rwxr-xr-x")
  assert_eq(mode_string("dir", "0750"), "drwxr-x---")
  assert_eq(mode_string("symlink", "0777"), "lrwxrwxrwx")
  assert_eq(mode_string("file", "4755"), "-rwsr-xr-x")
  assert_eq(mode_string("file", "4644"), "-rwSr--r--")
  assert_eq(mode_string("dir", "1777"), "drwxrwxrwt")
  assert_eq(mode_string("dir", "1776"), "drwxrwxrwT")
  assert_eq(mode_string("dir", "2755"), "drwxr-sr-x")
}

///|
test "rendering a package report" {
  let report : Json = {
    "format": "deb",
    "name": "hello",
    "version": "1.0-1",
    "architecture": "all",
    "maintainer": "Jane <jane@example.org>",
    "homepage": null,
    "installed_size_kib": "1",
    "description": "Says hello\nSecond line",
    "depends": ["bash (>= 4.0)", "coreutils"],
    "conffiles": ["/etc/hello.conf"],
    "scripts": ["postinst"],
    "compression": { "control": "gzip", "data": "gzip" },
    "files": [
      {
        "path": "/usr/bin/hello",
        "type": "file",
        "mode": "0755",
        "owner": "root",
        "group": "root",
        "size": 37,
        "link": null,
      },
      {
        "path": "/usr/bin/hi",
        "type": "symlink",
        "mode": "0777",
        "owner": "root",
        "group": "root",
        "size": 0,
        "link": "hello",
      },
    ],
  }
  inspect(
    render_report(report),
    content=(
      #|Package:       hello
      #|Version:       1.0-1
      #|Architecture:  all
      #|Maintainer:    Jane <jane@example.org>
      #|Installed size: 1 KiB
      #|Depends:       bash (>= 4.0), coreutils
      #|Description:   Says hello
      #|               Second line
      #|Scripts:       postinst
      #|Config files:  /etc/hello.conf
      #|Compression:   control gzip, data gzip
      #|
      #|Files (2):
      #|  -rwxr-xr-x  root/root         37  /usr/bin/hello
      #|  lrwxrwxrwx  root/root          0  /usr/bin/hi -> hello
      #|
    ),
  )
}

///|
test "inspect and verify need exactly one existing file" {
  assert_eq(run(["inspect"]), 1)
  assert_eq(run(["inspect", "a", "b"]), 1)
  assert_eq(run(["inspect", "does-not-exist.deb"]), 1)
  assert_eq(run(["verify"]), 1)
  assert_eq(run(["verify", "does-not-exist.deb"]), 1)
}
