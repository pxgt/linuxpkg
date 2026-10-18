///|
let full_config : String =
  #|{
  #|  "$schema": "https://example.org/linuxpkg.schema.json",
  #|  "name": "hello",
  #|  "version": "1.2.3",
  #|  "release": "4",
  #|  "epoch": 2,
  #|  "arch": "x86_64",
  #|  "maintainer": "Jane Doe <jane@example.org>",
  #|  "description": "Says hello\nA longer text.",
  #|  "homepage": "https://example.org/hello",
  #|  "license": "Apache-2.0",
  #|  "vendor": "Example Inc.",
  #|  "section": "utils",
  #|  "priority": "extra",
  #|  "depends": ["libc6 (>= 2.31)", "bash"],
  #|  "recommends": ["less"],
  #|  "suggests": ["man-db"],
  #|  "conflicts": ["hello-old (<< 1.0)"],
  #|  "replaces": ["hello-old"],
  #|  "provides": ["greeter"],
  #|  "mtime": 1700000000,
  #|  "contents": [
  #|    {"src": "bin/hello.sh", "dst": "/usr/bin/hello", "mode": "0755"},
  #|    {"src": "etc/hello.conf", "dst": "/etc/hello.conf", "type": "config"},
  #|    {"dst": "/var/lib/hello", "type": "dir", "mode": "0750", "owner": "hello", "group": "hello"},
  #|    {"src": "hello", "dst": "/usr/bin/hi", "type": "symlink"},
  #|    {"src": "bin/hello.sh", "dst": "/usr/local/bin/hello",
  #|     "file_info": {"mode": "0700", "owner": "root", "group": "staff", "mtime": 42}}
  #|  ],
  #|  "scripts": {"postinstall": "scripts/post.sh", "preremove": "scripts/pre-rm.sh"}
  #|}

///|
let minimal_config : String =
  #|{"name": "tiny", "version": "1", "arch": "all",
  #| "maintainer": "Jane <jane@example.org>", "description": "Tiny"}

///|
test "a full config is parsed into its parts" {
  let config = @spec.Config::parse(full_config)
  assert_eq(config.name, "hello")
  assert_eq(config.release, "4")
  assert_eq(config.epoch, 2)
  assert_eq(config.arch, @spec.Arch::Amd64)
  assert_eq(config.priority, "extra")
  assert_eq(config.homepage, Some("https://example.org/hello"))
  assert_eq(config.mtime, Some(1700000000L))
  assert_eq(config.depends.map(d => d.rpm_string()), ["libc6 >= 2.31", "bash"])
  assert_eq(config.contents.length(), 5)
  assert_eq(config.contents[0].kind, @spec.ContentKind::File)
  assert_eq(config.contents[0].mode, Some(0o755))
  assert_eq(config.contents[1].kind, @spec.ContentKind::ConfigFile)
  assert_eq(config.contents[2].kind, @spec.ContentKind::Dir)
  assert_eq(config.contents[2].owner, Some("hello"))
  assert_eq(config.contents[3].kind, @spec.ContentKind::Symlink)
  assert_eq(config.contents[3].src, Some("hello"))
  assert_eq(config.contents[4].mode, Some(0o700))
  assert_eq(config.contents[4].group, Some("staff"))
  assert_eq(config.contents[4].mtime, Some(42L))
  assert_eq(config.scripts.post_install, Some("scripts/post.sh"))
  assert_eq(config.scripts.pre_install, None)
}

///|
test "defaults" {
  let config = @spec.Config::parse(minimal_config)
  assert_eq(config.release, "1")
  assert_eq(config.epoch, 0)
  assert_eq(config.section, "misc")
  assert_eq(config.priority, "optional")
  assert_eq(config.contents.length(), 0)
  assert_eq(config.mtime, None)
  let spec = config.resolve(Map([]))
  assert_eq(spec.mtime, 0L)
  assert_eq(config.resolve(Map([]), default_mtime=99L).mtime, 99L)
}

///|
test "the config mtime wins over the default" {
  let text =
    #|{"name": "tiny", "version": "1", "arch": "all", "mtime": 5,
    #| "maintainer": "Jane <jane@example.org>", "description": "Tiny"}
  let config = @spec.Config::parse(text)
  assert_eq(config.resolve(Map([]), default_mtime=99L).mtime, 5L)
}

///|
test "sources lists each file once, scripts last" {
  let config = @spec.Config::parse(full_config)
  assert_eq(config.sources(), [
    "bin/hello.sh", "etc/hello.conf", "scripts/post.sh", "scripts/pre-rm.sh",
  ])
}

///|
test "resolve builds entries with kind specific defaults" {
  let config = @spec.Config::parse(full_config)
  let files : Map[String, Bytes] = {
    "bin/hello.sh": b"#!/bin/sh\necho hi\n",
    "etc/hello.conf": b"x=1\n",
    "scripts/post.sh": b"#!/bin/sh\nexit 0\n",
    "scripts/pre-rm.sh": b"#!/bin/sh\nexit 0\n",
  }
  let spec = config.resolve(files)
  assert_eq(spec.name, "hello")
  assert_eq(spec.epoch, 2)
  assert_eq(spec.mtime, 1700000000L)
  assert_eq(spec.scripts.post_install, Some("#!/bin/sh\nexit 0\n"))
  assert_eq(spec.scripts.post_remove, None)
  assert_eq(spec.entries, [
    @spec.Entry::file("/usr/bin/hello", b"#!/bin/sh\necho hi\n", mode=0o755),
    @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
    @spec.Entry::dir("/var/lib/hello", mode=0o750, owner="hello", group="hello"),
    @spec.Entry::symlink("/usr/bin/hi", "hello"),
    @spec.Entry::file(
      "/usr/local/bin/hello",
      b"#!/bin/sh\necho hi\n",
      mode=0o700,
      group="staff",
      mtime=42L,
    ),
  ])
}

///|
fn config_error(text : String) -> String {
  try @spec.Config::parse(text) catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
/// A valid config with one extra fragment spliced in.
fn with_extra(fragment : String) -> String {
  "{\"name\": \"tiny\", \"version\": \"1\", \"arch\": \"all\", \"maintainer\": \"Jane <j@example.org>\", \"description\": \"Tiny\", \{fragment}}"
}

///|
test "malformed input is rejected with the field name" {
  // The wording of JSON syntax errors belongs to the standard library.
  assert_true(config_error("{").has_prefix("json: "))
  inspect(config_error("[]"), content="config: must be an object")
  inspect(config_error("{}"), content="name: is required")
  inspect(config_error("{\"name\": 5}"), content="name: must be a string")
  inspect(
    config_error("{\"name\": \"a\", \"version\": \"1\"}"),
    content="arch: is required",
  )
  inspect(
    config_error(with_extra("\"colour\": \"red\"")),
    content="colour: unknown field, expected one of: name, version, release, epoch, arch, maintainer, description, homepage, license, vendor, section, priority, depends, recommends, suggests, conflicts, replaces, provides, mtime, contents, scripts",
  )
}

///|
test "value errors" {
  inspect(
    config_error(
      "{\"name\": \"a\", \"version\": \"1\", \"arch\": \"sparc\", \"maintainer\": \"m\", \"description\": \"d\"}",
    ),
    content="arch: unknown architecture \"sparc\" (try amd64, arm64, i386, armhf, armel, ppc64le, s390x, riscv64, loong64, mips64le or all)",
  )
  inspect(
    config_error(with_extra("\"epoch\": 1.5")),
    content="epoch: must be a whole number",
  )
  inspect(
    config_error(with_extra("\"epoch\": -1")),
    content="epoch: must be between 0 and 9007199254740992",
  )
  inspect(
    config_error(with_extra("\"epoch\": 4294967296")),
    content="epoch: must be between 0 and 2147483647",
  )
  inspect(
    config_error(with_extra("\"mtime\": \"yesterday\"")),
    content="mtime: must be a number",
  )
  inspect(
    config_error(with_extra("\"depends\": \"bash\"")),
    content="depends: must be an array of strings",
  )
  inspect(
    config_error(with_extra("\"depends\": [\"bash\", 7]")),
    content="depends[1]: must be a string",
  )
  inspect(
    config_error(with_extra("\"depends\": [\"a | b\"]")),
    content="depends[0]: alternatives ('|') and lists (',') are not supported, write one entry per package",
  )
  inspect(
    config_error(with_extra("\"contents\": {}")),
    content="contents: must be an array",
  )
}

///|
test "contents errors" {
  fn item(fragment : String) -> String {
    config_error(with_extra("\"contents\": [\{fragment}]"))
  }

  inspect(item("5"), content="contents[0]: must be an object")
  inspect(item("{}"), content="contents[0].dst: is required")
  inspect(
    item("{\"dst\": \"etc/x\", \"src\": \"x\"}"),
    content="contents[0].dst: must be an absolute path starting with '/'",
  )
  inspect(
    item("{\"dst\": \"/etc/x\"}"),
    content="contents[0].src: is required for files",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"\"}"),
    content="contents[0].src: must not be empty",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"type\": \"fifo\"}"),
    content="contents[0].type: unknown type \"fifo\", expected file, config, dir or symlink",
  )
  inspect(
    item("{\"dst\": \"/etc\", \"src\": \"x\", \"type\": \"dir\"}"),
    content="contents[0].src: is not allowed for directories",
  )
  inspect(
    item("{\"dst\": \"/usr/bin/x\", \"type\": \"symlink\"}"),
    content="contents[0].src: is required, it is the link target",
  )
  inspect(
    item(
      "{\"dst\": \"/usr/bin/x\", \"type\": \"symlink\", \"src\": \"y\", \"mode\": \"0755\"}",
    ),
    content="contents[0].mode: is not allowed for symbolic links",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"mode\": 755}"),
    content="contents[0].mode: must be a string such as \"0755\" (JSON numbers cannot be octal)",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"mode\": \"0888\"}"),
    content="contents[0].mode: must be an octal string such as \"0644\"",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"mode\": \"17777\"}"),
    content="contents[0].mode: must be between 0 and 07777 (octal), got 17777",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"owner\": \"a:b\"}"),
    content="contents[0].owner: contains \":\", only letters, digits, '_', '-' and '.' are allowed",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"colour\": 1}"),
    content="contents[0].colour: unknown field, expected one of: src, dst, type, mode, owner, group, mtime, file_info",
  )
  inspect(
    item(
      "{\"dst\": \"/etc/x\", \"src\": \"x\", \"mode\": \"0644\", \"file_info\": {\"mode\": \"0600\"}}",
    ),
    content="contents[0].mode: cannot be combined with file_info, put it inside file_info",
  )
  inspect(
    item("{\"dst\": \"/etc/x\", \"src\": \"x\", \"file_info\": {\"size\": 1}}"),
    content="contents[0].file_info.size: unknown field, expected one of: mode, owner, group, mtime",
  )
  inspect(
    item(
      "{\"dst\": \"/etc/x\", \"src\": \"x\", \"file_info\": {\"mode\": \"0888\"}}",
    ),
    content="contents[0].file_info.mode: must be an octal string such as \"0644\"",
  )
}

///|
test "scripts errors" {
  inspect(
    config_error(with_extra("\"scripts\": 1")),
    content="scripts: must be an object",
  )
  inspect(
    config_error(with_extra("\"scripts\": {\"install\": \"x\"}")),
    content="scripts.install: unknown field, expected one of: preinstall, postinstall, preremove, postremove",
  )
  inspect(
    config_error(with_extra("\"scripts\": {\"preinstall\": 3}")),
    content="scripts.preinstall: must be a string",
  )
}

///|
fn resolve_error(text : String, files : Map[String, Bytes]) -> String {
  try {
    let config = @spec.Config::parse(text)
    ignore(config.resolve(files))
  } catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "resolve reports missing files and invalid packages" {
  let with_file = with_extra(
    "\"contents\": [{\"src\": \"a.txt\", \"dst\": \"/opt/a\"}]",
  )
  inspect(
    resolve_error(with_file, Map([])),
    content="contents[0].src: file \"a.txt\" was not provided",
  )
  inspect(resolve_error(with_file, { "a.txt": b"a" }), content="ok")
  let with_script = with_extra("\"scripts\": {\"postinstall\": \"p.sh\"}")
  inspect(
    resolve_error(with_script, Map([])),
    content="scripts.postinstall: file \"p.sh\" was not provided",
  )
  inspect(
    resolve_error(with_script, { "p.sh": b"\xff\xfe" }),
    content="scripts.postinstall: file \"p.sh\" is not valid UTF-8 text",
  )
  // Whole package rules still apply after parsing.
  let duplicate = with_extra(
    "\"contents\": [{\"src\": \"a\", \"dst\": \"/opt/a\"}, {\"src\": \"b\", \"dst\": \"/opt/a\"}]",
  )
  inspect(
    resolve_error(duplicate, { "a": b"a", "b": b"b" }),
    content="entries[1].path: \"/opt/a\" is already used by entries[0]",
  )
  let bad_name = "{\"name\": \"Bad\", \"version\": \"1\", \"arch\": \"all\", \"maintainer\": \"m\", \"description\": \"d\"}"
  inspect(resolve_error(bad_name, Map([])), content="name: must be lowercase")
}
