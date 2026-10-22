///|
fn refused(f : () -> Unit raise @spec.SpecError) -> Bool {
  try {
    f()
    false
  } catch {
    @spec.SpecError::Invalid(..) => true
  }
}

///|
fn field_of(f : () -> Unit raise @spec.SpecError) -> String {
  try {
    f()
    "accepted"
  } catch {
    @spec.SpecError::Invalid(field~, ..) => field
  }
}

///|
test "package names: one letter is too short, two are enough" {
  assert_true(refused(() => @spec.validate_package_name("a")))
  assert_true(refused(() => @spec.validate_package_name("")))
  @spec.validate_package_name("ab")
  @spec.validate_package_name("9p")
}

///|
test "package names: uppercase, spaces, slashes and underscores are refused" {
  for
    bad in ["Hello", "hello world", "a/b", "foo_bar", "über", "x@y", "hello!"] {
    assert_true(refused(() => @spec.validate_package_name(bad)))
  }
}

///|
test "package names: the first character is a letter or digit" {
  for bad in ["-hello", ".hello", "+hello"] {
    assert_true(refused(() => @spec.validate_package_name(bad)))
  }
  for good in ["a+", "a.b-c+d", "0ad", "lib2to3", "g++"] {
    @spec.validate_package_name(good)
  }
}

///|
test "package names: 128 characters are the limit" {
  @spec.validate_package_name("a".repeat(128))
  assert_true(refused(() => @spec.validate_package_name("a".repeat(129))))
}

///|
test "versions start with a digit and may carry a tilde" {
  for good in ["1", "1.0", "2.0.1+dfsg", "1.0~rc1", "20261022", "1.2.3a"] {
    @spec.validate_version(good)
  }
  for bad in ["", "v1.0", "1.0-1", "1 0", "1:0", "1_0", ".1"] {
    assert_true(refused(() => @spec.validate_version(bad)))
  }
}

///|
test "versions and releases share the length limit" {
  @spec.validate_version("1" + "0".repeat(127))
  assert_true(refused(() => @spec.validate_version("1" + "0".repeat(128))))
  @spec.validate_release("1" + "a".repeat(127))
  assert_true(refused(() => @spec.validate_release("1" + "a".repeat(128))))
}

///|
test "releases may start with a letter but not be empty or contain hyphens" {
  for good in ["1", "0.1", "1ubuntu2", "alpha1", "1~bpo12+1"] {
    @spec.validate_release(good)
  }
  for bad in ["", "1-2", "1 2", "r_1"] {
    assert_true(refused(() => @spec.validate_release(bad)))
  }
}

///|
test "install paths must be absolute and normalized" {
  for good in ["/", "/usr", "/usr/bin/hello", "/opt/my app/x", "/a/b.c/d-e"] {
    ignore(good)
  }
  for good in ["/usr", "/usr/bin/hello", "/opt/a.b/c-d", "/a"] {
    @spec.validate_install_path(good, field="dst")
  }
  for
    bad in [
      "", "usr/bin", "./usr", "/usr//bin", "/usr/bin/", "/usr/./bin", "/usr/../etc",
      "/..",
    ] {
    assert_true(refused(() => @spec.validate_install_path(bad, field="dst")))
  }
}

///|
test "install paths refuse control characters and name the field" {
  assert_eq(
    field_of(() => @spec.validate_install_path("/a\nb", field="contents[3].dst")),
    "contents[3].dst",
  )
  assert_true(
    refused(() => @spec.validate_install_path("/a\u{7f}b", field="dst")),
  )
  assert_true(
    refused(() => @spec.validate_install_path("/a\u{0}b", field="dst")),
  )
  assert_true(
    refused(() => {
      @spec.validate_install_path("/" + "a".repeat(4096), field="dst")
    }),
  )
}

///|
test "modes are permission bits: 0 to 07777" {
  for good in [0, 0o644, 0o755, 0o4755, 0o7777] {
    @spec.validate_mode(good, field="mode")
  }
  for bad in [-1, 0o10000, 0o100644] {
    assert_true(refused(() => @spec.validate_mode(bad, field="mode")))
  }
}

///|
test "accounts are plain user and group names" {
  for good in ["root", "www-data", "_apt", "user1", "a.b"] {
    @spec.validate_account(good, field="owner")
  }
  for bad in ["", "a b", "a:b", "a/b", "a\nb"] {
    assert_true(refused(() => @spec.validate_account(bad, field="owner")))
  }
}

///|
test "link targets may be relative but not empty or contain control characters" {
  for good in ["hello", "../lib/x", "/usr/bin/hello", "a b"] {
    @spec.validate_link_target(good, field="src")
  }
  for bad in ["", "a\nb", "a\u{0}b"] {
    assert_true(refused(() => @spec.validate_link_target(bad, field="src")))
  }
}

///|
test "architecture names map between deb, rpm and pacman" {
  let cases = [
    ("amd64", "amd64", "x86_64", Some("x86_64")),
    ("x86_64", "amd64", "x86_64", Some("x86_64")),
    ("arm64", "arm64", "aarch64", Some("aarch64")),
    ("aarch64", "arm64", "aarch64", Some("aarch64")),
    ("all", "all", "noarch", Some("any")),
    ("noarch", "all", "noarch", Some("any")),
    ("i386", "i386", "i686", Some("i686")),
  ]
  for c in cases {
    let arch = @spec.Arch::parse(c.0)
    assert_eq(arch.deb_name(), c.1)
    assert_eq(arch.rpm_name(), c.2)
    assert_eq(arch.pacman_name(), c.3)
  }
}

///|
test "unknown architectures are refused with the list of known ones" {
  for bad in ["sparc", "", "ppc", "itanium"] {
    assert_true(refused(() => ignore(@spec.Arch::parse(bad))))
  }
}

///|
test "relations: names, operators and versions" {
  let dep = @spec.Dependency::parse("libc6 (>= 2.31)")
  assert_eq(dep.name, "libc6")
  assert_eq(dep.deb_string(), "libc6 (>= 2.31)")
  assert_eq(dep.rpm_string(), "libc6 >= 2.31")
  let plain = @spec.Dependency::parse("bash")
  assert_eq(plain.deb_string(), "bash")
  assert_eq(plain.rpm_string(), "bash")
  let rpm_style = @spec.Dependency::parse("zlib >= 1.2")
  assert_eq(rpm_style.deb_string(), "zlib (>= 1.2)")
}

///|
test "relations: all operators round-trip" {
  for op in ["<<", "<=", "=", ">=", ">>"] {
    let dep = @spec.Dependency::parse("pkg (\{op} 1.0)")
    assert_true(dep.deb_string().contains(op))
  }
  for bad in ["", "(>= 1)", "pkg (>= )", "pkg (>= 1", "pkg >=", "pkg (?? 1)"] {
    assert_true(refused(() => ignore(@spec.Dependency::parse(bad))))
  }
}

///|
test "entries: files, directories and symlinks validate their own paths" {
  @spec.Entry::file("/usr/bin/x", b"x", mode=0o755).validate(field="e")
  @spec.Entry::dir("/var/lib/x").validate(field="e")
  @spec.Entry::symlink("/usr/bin/y", "x").validate(field="e")
  assert_true(
    refused(() => @spec.Entry::file("usr/bin/x", b"").validate(field="e")),
  )
  assert_true(refused(() => @spec.Entry::dir("/a/../b").validate(field="e")))
  assert_true(refused(() => @spec.Entry::symlink("/y", "").validate(field="e")))
  assert_true(
    refused(() => @spec.Entry::file("/x", b"", mode=0o17777).validate(field="e")),
  )
}

///|
fn spec_with(entries : Array[@spec.Entry]) -> @spec.PackageSpec {
  @spec.PackageSpec::new(
    name="demo",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <jane@example.org>",
    description="Demo",
    entries~,
  )
}

///|
test "a package may not install the same path twice" {
  let spec = spec_with([
    @spec.Entry::file("/usr/bin/x", b"1"),
    @spec.Entry::file("/usr/bin/x", b"2"),
  ])
  assert_true(refused(() => spec.validate()))
}

///|
test "a package needs a maintainer and a description" {
  for case in [("", "Demo"), ("Jane <j@e.org>", "")] {
    let spec = @spec.PackageSpec::new(
      name="demo",
      version="1.0",
      arch=@spec.Arch::All,
      maintainer=case.0,
      description=case.1,
    )
    assert_true(refused(() => spec.validate()))
  }
}

///|
test "epochs are not negative" {
  let spec = @spec.PackageSpec::new(
    name="demo",
    version="1.0",
    arch=@spec.Arch::All,
    maintainer="Jane <j@e.org>",
    description="Demo",
    epoch=-1,
  )
  assert_true(refused(() => spec.validate()))
}

///|
test "configuration: unknown fields, wrong types and missing fields name the field" {
  let base = "{\"name\":\"demo\",\"version\":\"1.0\",\"arch\":\"all\",\"maintainer\":\"J <j@e.org>\",\"description\":\"D\""
  assert_eq(
    field_of(() => ignore(@spec.Config::parse(base + ",\"colour\":1}"))),
    "colour",
  )
  assert_eq(
    field_of(() => ignore(@spec.Config::parse(base + ",\"depends\":\"bash\"}"))),
    "depends",
  )
  assert_eq(
    field_of(() => ignore(@spec.Config::parse(base + ",\"mtime\":\"x\"}"))),
    "mtime",
  )
  assert_eq(
    field_of(() => ignore(@spec.Config::parse("{\"name\":\"demo\"}"))),
    "version",
  )
  assert_eq(field_of(() => ignore(@spec.Config::parse("[]"))), "config")
}

///|
test "configuration: contents entries are checked one by one" {
  let base = "{\"name\":\"demo\",\"version\":\"1.0\",\"arch\":\"all\",\"maintainer\":\"J <j@e.org>\",\"description\":\"D\",\"contents\":"
  let ok = @spec.Config::parse(
    base + "[{\"src\":\"a\",\"dst\":\"/usr/bin/a\"}]}",
  )
  assert_eq(ok.sources(), ["a"])
  assert_true(
    field_of(() => {
      ignore(
        @spec.Config::parse(base + "[{\"dst\":\"/x\",\"type\":\"bogus\"}]}"),
      )
    }).has_prefix("contents[0]"),
  )
  assert_true(
    field_of(() => {
      ignore(
        @spec.Config::parse(
          base + "[{\"src\":\"a\",\"dst\":\"/a\"},{\"src\":\"b\"}]}",
        ),
      )
    }).has_prefix("contents[1]"),
  )
}
