///|
fn env_of(pairs : Array[(String, String)]) -> (String) -> String {
  name => {
    for pair in pairs {
      if pair.0 == name {
        return pair.1
      }
    }
    ""
  }
}

///|
test "expand follows Go's os.Expand" {
  let lookup = env_of([("A", "1"), ("BC", "two"), ("$", "dollar"), ("1", "one")])
  assert_eq(expand("plain", lookup), "plain")
  assert_eq(expand("$A", lookup), "1")
  assert_eq(expand("${A}x", lookup), "1x")
  assert_eq(expand("$Ax", lookup), "")
  assert_eq(expand("$A-$BC.", lookup), "1-two.")
  assert_eq(expand("${BC}${A}", lookup), "two1")
  // A dollar that does not start a name stays; "${}" and "${" are dropped.
  assert_eq(expand("cost $", lookup), "cost $")
  assert_eq(expand("a $ b", lookup), "a $ b")
  assert_eq(expand("x${}y", lookup), "xy")
  assert_eq(expand("x${y", lookup), "xy")
  // Special one-character names, and no default value syntax.
  assert_eq(expand("$$", lookup), "dollar")
  assert_eq(expand("$1", lookup), "one")
  assert_eq(expand("${A:-fallback}", lookup), "")
  assert_eq(expand("${1}", lookup), "one")
  // Unset variables are empty; non-ASCII text passes through.
  assert_eq(expand("é$NOPE€", lookup), "é€")
}

///|
fn split_of(text : String) -> String? {
  match parse_semver(text) {
    Some(v) =>
      Some("\{v.major}.\{v.minor}.\{v.patch}|\{v.prerelease}|\{v.metadata}")
    None => None
  }
}

///|
test "versions are split like Masterminds semver" {
  assert_eq(split_of("1.2.3"), Some("1.2.3||"))
  assert_eq(split_of("v1.2.3-beta"), Some("1.2.3|beta|"))
  assert_eq(split_of("v1.2.3-rc.1+git.abc"), Some("1.2.3|rc.1|git.abc"))
  assert_eq(split_of("1.2"), Some("1.2.0||"))
  assert_eq(split_of("v3"), Some("3.0.0||"))
  assert_eq(split_of("1.0.0+build5"), Some("1.0.0||build5"))
  assert_eq(split_of("not a version"), None)
  assert_true(parse_semver("1.2.3.4") is None)
  assert_true(parse_semver("1.2.3-01") is None)
  assert_true(parse_semver("1.2.x") is None)
  assert_true(parse_semver("") is None)
  assert_true(parse_semver("1.2.3-") is None)
  // schema "none" keeps the text.
  assert_eq(
    settle_version("v1.2.3-beta", "", "", "none"),
    ("v1.2.3-beta", "", ""),
  )
  assert_eq(
    settle_version("v1.2.3-beta", "", "", "semver"),
    ("1.2.3", "beta", ""),
  )
  // A pre-release in the file wins over the one in the version.
  assert_eq(settle_version("1.2.3-beta", "rc1", "", ""), ("1.2.3", "rc1", ""))
  assert_eq(settle_version("garbage", "x", "y", ""), ("garbage", "x", "y"))
}

///|
test "numbers that must stay text are quoted, block scalars are left alone" {
  let text =
    #|name: foo
    #|version: 1.10
    #|release: 02
    #|epoch: 3
    #|contents:
    #|  - src: a
    #|    file_info:
    #|      mode: 0755
    #|  - src: b
    #|    file_info: {mode: 04755, owner: x}
    #|  - src: c
    #|    file_info: {mode: "0644"}
    #|description: |
    #|  version: 9.9
    #|  mode: 0600
    #|maintainer: x # version: 5
    #|homepage: https://example.org/mode: 12
  let quoted = quote_numbers(text)
  assert_true(quoted.contains("version: \"1.10\"\n"))
  assert_true(quoted.contains("release: \"02\"\n"))
  assert_true(quoted.contains("epoch: \"3\"\n"))
  assert_true(quoted.contains("      mode: \"0755\"\n"))
  assert_true(quoted.contains("{mode: \"04755\", owner: x}"))
  assert_true(quoted.contains("{mode: \"0644\"}"))
  assert_true(quoted.contains("  version: 9.9\n  mode: 0600\n"))
  assert_true(quoted.contains("maintainer: x # version: 5\n"))
  assert_true(quoted.contains("example.org/mode: 12"))
}

///|
test "glob patterns" {
  assert_true(glob_match("a/*.txt", "a/b.txt"))
  assert_false(glob_match("a/*.txt", "a/b/c.txt"))
  assert_true(glob_match("a/**/c.txt", "a/b/c.txt"))
  assert_false(glob_match("a/**/c.txt", "a/c.txt"))
  assert_true(glob_match("a/**", "a/b/c/d"))
  assert_true(glob_match("a/?.txt", "a/b.txt"))
  assert_false(glob_match("a/?.txt", "a/bb.txt"))
  assert_true(glob_match("a/[bc].txt", "a/c.txt"))
  assert_false(glob_match("a/[!bc].txt", "a/c.txt"))
  assert_true(glob_match("a/[a-c]x", "a/bx"))
  assert_false(glob_match("a/*", "a"))
  assert_eq(go_dir("a/b/c"), "a/b")
  assert_eq(go_dir("a/b/"), "a/b")
  assert_eq(go_dir("a"), ".")
  assert_eq(go_dir("/a"), "/")
  assert_eq(base_name("a/b/c.txt"), "c.txt")
  assert_eq(clean_path("./a//b/./c"), "a/b/c")
  assert_eq(longest_common_prefix(["a/b/c", "a/b/d", "a/bx"]), "a/b")
}

///|
test "timestamps" {
  assert_eq(parse_timestamp("1970-01-01"), Some(0L))
  assert_eq(parse_timestamp("1970-01-02T00:00:00Z"), Some(86400L))
  assert_eq(parse_timestamp("2024-02-29 12:30:15"), Some(1709209815L))
  assert_eq(parse_timestamp("2024-02-29T12:30:15.5+02:00"), Some(1709202615L))
  assert_eq(parse_timestamp("2024-02-29T12:30:15-01:30"), Some(1709215215L))
  assert_eq(parse_timestamp("yesterday"), None)
  assert_eq(parse_timestamp("2024-13-01"), None)
  assert_eq(parse_timestamp("2024-02-29T25:00:00Z"), None)
}

///|
test "modes are normalized" {
  assert_eq(mode_text("0755", "m"), "0755")
  assert_eq(mode_text("755", "m"), "0755")
  assert_eq(mode_text("0o644", "m"), "0644")
  assert_eq(mode_text("04755", "m"), "4755")
  assert_eq(mode_text("0", "m"), "0000")
  for bad in ["", "0789", "rwx", "0x1ff", "1234567"] {
    try mode_text(bad, "m") catch {
      Invalid(message) => assert_true(message.has_prefix("m: "))
    } noraise {
      _ => fail("\{bad} must be refused")
    }
  }
}
