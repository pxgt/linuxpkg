///|
fn parse_or_error(text : String) -> String {
  try {
    let dep = @spec.Dependency::parse(text)
    "\{dep.deb_string()} | \{dep.rpm_string()}"
  } catch {
    err => "error: \{err}"
  }
}

///|
test "parse Debian style relations" {
  inspect(parse_or_error("bash"), content="bash | bash")
  inspect(
    parse_or_error("libc6 (>= 2.31)"),
    content="libc6 (>= 2.31) | libc6 >= 2.31",
  )
  inspect(
    parse_or_error("  libfoo(<<1.0~rc1)  "),
    content="libfoo (<< 1.0~rc1) | libfoo < 1.0~rc1",
  )
  inspect(
    parse_or_error("foo (= 1:2.0-3)"),
    content="foo (= 1:2.0-3) | foo = 1:2.0-3",
  )
  inspect(parse_or_error("/bin/sh"), content="/bin/sh | /bin/sh")
}

///|
test "parse RPM style relations" {
  inspect(
    parse_or_error("glibc >= 2.34"),
    content="glibc (>= 2.34) | glibc >= 2.34",
  )
  inspect(
    parse_or_error("openssl<3.0"),
    content="openssl (<< 3.0) | openssl < 3.0",
  )
  inspect(parse_or_error("zlib > 1.2"), content="zlib (>> 1.2) | zlib > 1.2")
  inspect(parse_or_error("zlib == 1.2"), content="zlib (= 1.2) | zlib = 1.2")
  inspect(parse_or_error("zlib <= 1.3"), content="zlib (<= 1.3) | zlib <= 1.3")
}

///|
test "parse structure" {
  let dep = @spec.Dependency::parse("libc6 (>= 2.31)")
  assert_eq(dep, {
    name: "libc6",
    constraint: Some((@spec.VersionOp::Ge, "2.31")),
  })
  let plain = @spec.Dependency::parse("bash")
  assert_eq(plain, { name: "bash", constraint: None, })
}

///|
test "reject malformed relations" {
  inspect(
    parse_or_error(""),
    content="error: dependency: package name must not be empty",
  )
  inspect(
    parse_or_error("   "),
    content="error: dependency: package name must not be empty",
  )
  inspect(
    parse_or_error("(>= 1.0)"),
    content="error: dependency: package name must not be empty",
  )
  inspect(
    parse_or_error("foo (>= 1.0"),
    content="error: dependency: missing ')' in \"foo (>= 1.0\"",
  )
  inspect(
    parse_or_error("foo (~ 1.0)"),
    content="error: dependency: expected one of <<, <, <=, =, >=, >, >> before the version in \"foo (~ 1.0)\"",
  )
  inspect(
    parse_or_error("foo (>=)"),
    content="error: dependency: version after the operator must not be empty",
  )
  inspect(
    parse_or_error("foo (>= 1.0 2.0)"),
    content="error: dependency: version \"1.0 2.0\" contains \" \"",
  )
  inspect(
    parse_or_error("foo | bar"),
    content="error: dependency: alternatives ('|') and lists (',') are not supported, write one entry per package",
  )
  inspect(
    parse_or_error("foo, bar"),
    content="error: dependency: alternatives ('|') and lists (',') are not supported, write one entry per package",
  )
}

///|
test "hand built relations are validated" {
  @spec.Dependency::validate(
    { name: "bash", constraint: None, },
    field="depends[0]",
  )
  try
    @spec.Dependency::validate(
      { name: "a b", constraint: None, },
      field="depends[1]",
    )
  catch {
    err =>
      inspect(
        "\{err}",
        content="depends[1]: package name \"a b\" contains \" \", alternatives and lists are not supported, write one entry per package",
      )
  } noraise {
    _ => fail("expected an error")
  }
}
