///|
/// A host with files in memory and some environment variables.
fn host_of(
  files : Array[(String, Bytes)],
  env~ : Array[(String, String)] = [],
) -> @nfpm.Host {
  let table : Map[String, Bytes] = Map([])
  for file in files {
    table[file.0] = file.1
  }
  {
    getenv: name => {
      for pair in env {
        if pair.0 == name {
          return Some(pair.1)
        }
      }
      None
    },
    read_file: path => table.get(path),
    list_dir: path => {
      let prefix = if path == "." { "" } else { path + "/" }
      let names : Array[String] = []
      let mut found = false
      for key, _ in table {
        if key.has_prefix(prefix) {
          found = true
          let rest = key[prefix.length():].to_owned()
          let name = match rest.find("/") {
            Some(at) => rest[0:at].to_owned()
            None => rest
          }
          if !names.contains(name) {
            names.push(name)
          }
        }
      }
      if found {
        Some(names)
      } else {
        None
      }
    },
  }
}

///|
fn convert_ok(
  yaml : String,
  host~ : @nfpm.Host = @nfpm.Host::empty(),
  format~ : String = "",
) -> (Map[String, Json], Array[String]) raise {
  let converted = @nfpm.convert(yaml, host, format~)
  guard converted.config is Object(map) else { fail("object expected") }
  // What comes out must be a configuration that linuxpkg accepts.
  ignore(@spec.Config::parse(converted.config.stringify()))
  (map, converted.warnings)
}

///|
fn convert_error(
  yaml : String,
  host~ : @nfpm.Host = @nfpm.Host::empty(),
  format~ : String = "",
) -> String {
  try @nfpm.convert(yaml, host, format~) catch {
    err => "\{err}"
  } noraise {
    _ => "no error"
  }
}

///|
fn text_at(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(String(text)) => text
    Some(other) => other.stringify()
    None => "<none>"
  }
}

///|
fn contents_of(map : Map[String, Json]) -> Array[Map[String, Json]] {
  let result : Array[Map[String, Json]] = []
  match map.get("contents") {
    Some(Array(items)) =>
      for item in items {
        if item is Object(entry) {
          result.push(entry)
        }
      }
    _ => ()
  }
  result
}

///|
let simple =
  #|name: "foo"
  #|arch: "amd64"
  #|platform: "linux"
  #|version: "v1.2.3-beta"
  #|maintainer: "Foo Bar <foo@example.org>"
  #|depends:
  #|  - bash
  #|  - libc6 (>= 2.31)
  #|provides:
  #|  - fake
  #|description: |
  #|  Foo bar
  #|    Multiple lines
  #|license: "MIT"
  #|contents:
  #|  - src: ./bin/fake
  #|    dst: /usr/bin/fake
  #|  - src: ./etc/whatever.conf
  #|    dst: /etc/foo/whatever.conf
  #|    type: config
  #|  - dst: /var/log/whatever
  #|    type: dir
  #|    file_info:
  #|      mode: 0750
  #|      owner: foo
  #|  - src: fake
  #|    dst: /usr/bin/fake2
  #|    type: symlink
  #|scripts:
  #|  postinstall: ./scripts/post.sh

///|
test "a plain nFPM configuration becomes a linuxpkg configuration" {
  let host = host_of([
    ("./bin/fake", b"#!/bin/sh\necho fake\n"),
    ("etc/whatever.conf", b"x=1\n"),
  ])
  let (map, warnings) = convert_ok(simple, host~)
  assert_eq(warnings, [])
  assert_eq(text_at(map, "name"), "foo")
  assert_eq(text_at(map, "version"), "1.2.3~beta")
  assert_eq(text_at(map, "arch"), "amd64")
  assert_eq(text_at(map, "maintainer"), "Foo Bar <foo@example.org>")
  assert_eq(text_at(map, "description"), "Foo bar\n  Multiple lines\n")
  assert_eq(text_at(map, "license"), "MIT")
  assert_eq(
    map.get("depends"),
    Some(Json::array([Json::string("bash"), Json::string("libc6 (>= 2.31)")])),
  )
  assert_eq(
    map.get("scripts"),
    Some(Json::object({ "postinstall": Json::string("./scripts/post.sh") })),
  )
  let contents = contents_of(map)
  assert_eq(contents.length(), 4)
  assert_eq(text_at(contents[0], "dst"), "/usr/bin/fake")
  // The script is executable: nFPM would copy the mode of the file, here it
  // is recognized from the first line.
  assert_eq(text_at(contents[0], "mode"), "0755")
  assert_eq(text_at(contents[1], "type"), "config")
  assert_eq(text_at(contents[2], "type"), "dir")
  assert_eq(text_at(contents[2], "mode"), "0750")
  assert_eq(text_at(contents[2], "owner"), "foo")
  assert_eq(text_at(contents[3], "type"), "symlink")
  assert_eq(text_at(contents[3], "src"), "fake")
}

///|
test "environment variables are expanded in the fields nFPM expands" {
  let yaml =
    #|name: "$PKG"
    #|arch: "${BUILD_ARCH}"
    #|version: "${SEMVER}"
    #|release: "$REL"
    #|maintainer: "Foo <foo@example.org>"
    #|license: "$KEPT"
    #|description: "built for $BUILD_ARCH, cost $5 or $"
    #|depends:
    #|  - "bash $MIN"
    #|  - "$NOTHING"
    #|contents:
    #|  - src: a
    #|    dst: /opt/$PKG/a
    #|  - src: b
    #|    dst: /opt/$PKG/b
    #|    expand: true
  let host = host_of([("a", b"1"), ("b", b"2")], env=[
    ("PKG", "tool"),
    ("BUILD_ARCH", "arm64"),
    ("SEMVER", "v2.0.1"),
    ("REL", "7"),
    ("MIN", "(>= 4)"),
    ("KEPT", "x"),
  ])
  let (map, _) = convert_ok(yaml, host~)
  assert_eq(text_at(map, "name"), "tool")
  assert_eq(text_at(map, "arch"), "arm64")
  assert_eq(text_at(map, "version"), "2.0.1")
  assert_eq(text_at(map, "release"), "7")
  // Not expanded: license (like nFPM).
  assert_eq(text_at(map, "license"), "$KEPT")
  // $5 is a variable called "5", empty; a lone $ stays.
  assert_eq(text_at(map, "description"), "built for arm64, cost  or $")
  // Items of lists are expanded and trimmed, empty ones dropped.
  assert_eq(
    map.get("depends"),
    Some(Json::array([Json::string("bash (>= 4)")])),
  )
  // Contents only with "expand: true".
  let contents = contents_of(map)
  assert_eq(text_at(contents[0], "dst"), "/opt/$PKG/a")
  assert_eq(text_at(contents[1], "dst"), "/opt/tool/b")
}

///|
test "the version is split into version, pre-release and metadata like nFPM" {
  let base =
    #|name: x
    #|arch: amd64
    #|maintainer: "A <a@example.org>"
  let version = (v : String, extra : String) => {
    let (map, _) = convert_ok(base + "\nversion: " + v + extra)
    text_at(map, "version")
  }
  assert_eq(version("1.2.3", ""), "1.2.3")
  assert_eq(version("v1.2.3-rc.1+git", ""), "1.2.3~rc.1+git")
  assert_eq(version("1.2.3-beta-2", ""), "1.2.3~beta.2")
  assert_eq(version("1.10", ""), "1.10.0")
  // A number stays text: 1.10 is not 1.1.
  assert_eq(version("1.10", "\nversion_schema: none"), "1.10")
  // The pre-release in the file wins.
  assert_eq(version("1.2.3-beta", "\nprerelease: rc1"), "1.2.3~rc1")
  assert_eq(version("1.2.3", "\nversion_metadata: git"), "1.2.3+git")
  assert_eq(
    version("\"not a version\"", "\nversion_schema: none"),
    "not a version",
  )
}

///|
test "overrides, packager-specific contents and per-format settings" {
  let yaml =
    #|name: foo
    #|arch: amd64
    #|version: 1.0.0
    #|maintainer: "A <a@example.org>"
    #|depends:
    #|  - bash
    #|contents:
    #|  - src: a
    #|    dst: /usr/bin/a
    #|  - src: only-deb
    #|    dst: /usr/bin/d
    #|    packager: deb
    #|  - src: only-rpm
    #|    dst: /usr/bin/r
    #|    packager: rpm
    #|scripts:
    #|  postinstall: base-post.sh
    #|overrides:
    #|  deb:
    #|    depends:
    #|      - dpkg
    #|    scripts:
    #|      postinstall: deb-post.sh
    #|    deb:
    #|      compression: xz
    #|  rpm:
    #|    depends:
    #|      - rpm-libs
    #|    rpm:
    #|      compression: zstd
    #|      arch: x86_64
    #|  apk:
    #|    apk:
    #|      arch: x86_64
  let host = host_of([("a", b"a"), ("only-deb", b"d"), ("only-rpm", b"r")])
  let (deb, deb_warnings) = convert_ok(yaml, host~, format="deb")
  assert_eq(deb_warnings, [])
  assert_eq(deb.get("depends"), Some(Json::array([Json::string("dpkg")])))
  assert_eq(
    deb.get("scripts"),
    Some(Json::object({ "postinstall": Json::string("deb-post.sh") })),
  )
  assert_eq(
    deb.get("deb"),
    Some(Json::object({ "compression": Json::string("xz") })),
  )
  assert_eq(deb.get("rpm"), None)
  assert_eq(contents_of(deb).map(c => text_at(c, "dst")), [
    "/usr/bin/a", "/usr/bin/d",
  ])
  let (rpm, _) = convert_ok(yaml, host~, format="rpm")
  assert_eq(rpm.get("depends"), Some(Json::array([Json::string("rpm-libs")])))
  assert_eq(
    rpm.get("rpm"),
    Some(Json::object({ "compression": Json::string("zstd") })),
  )
  assert_eq(text_at(rpm, "arch"), "x86_64")
  assert_eq(contents_of(rpm).map(c => text_at(c, "dst")), [
    "/usr/bin/a", "/usr/bin/r",
  ])
  // A format without overrides, the alias for archlinux.
  let (arch, _) = convert_ok(yaml, host~, format="arch")
  assert_eq(arch.get("depends"), Some(Json::array([Json::string("bash")])))
  let (apk, _) = convert_ok(yaml, host~, format="apk")
  assert_eq(text_at(apk, "arch"), "x86_64")
  // Without a format: the base, with a warning naming what was left out.
  let (base, warnings) = convert_ok(yaml, host~)
  assert_eq(contents_of(base).length(), 1)
  assert_eq(base.get("depends"), Some(Json::array([Json::string("bash")])))
  assert_true(warnings.any(w => w.contains("overrides for deb, rpm, apk")))
  assert_true(warnings.any(w => w.contains("only for deb")))
  assert_true(
    convert_error(yaml, host~, format="msi").contains("unknown format"),
  )
}

///|
test "nFPM architecture names" {
  let arch = (name : String) => {
    let (map, _) = convert_ok(
      "name: x\nversion: 1\nmaintainer: \"A <a@example.org>\"\narch: " + name,
    )
    text_at(map, "arch")
  }
  assert_eq(arch("amd64"), "amd64")
  assert_eq(arch("386"), "i386")
  assert_eq(arch("arm5"), "armel")
  assert_eq(arch("arm6"), "armhf")
  assert_eq(arch("arm7"), "armhf")
  assert_eq(arch("s390"), "s390x")
  assert_eq(arch("ppc64le"), "ppc64le")
  assert_eq(arch("all"), "all")
  // Left out, nFPM builds for amd64.
  let (none, _) = convert_ok(
    "name: x\nversion: 1\nmaintainer: \"A <a@example.org>\"",
  )
  assert_eq(text_at(none, "arch"), "amd64")
  // An architecture linuxpkg has no name for is an error from the configuration reader.
  let converted = @nfpm.convert(
    "name: x\nversion: 1\nmaintainer: \"A <a@example.org>\"\narch: mipsle",
    @nfpm.Host::empty(),
  )
  let bad = try @spec.Config::parse(converted.config.stringify()) catch {
    err => "\{err}"
  } noraise {
    _ => "no error"
  }
  assert_true(bad.contains("mipsle"))
}

///|
test "unknown fields are errors, unsupported ones are named and skipped" {
  let base =
    #|name: x
    #|version: 1
    #|maintainer: "A <a@example.org>"
  assert_eq(convert_error(base + "\ncolour: red"), "colour: unknown field")
  assert_eq(
    convert_error(
      base + "\ncontents:\n  - dst: /a\n    type: dir\n    colour: red",
    ),
    "contents[0].colour: unknown field",
  )
  assert_eq(
    convert_error(base + "\nrpm:\n  scripts:\n    nope: x"),
    "rpm.scripts.nope: unknown field",
  )
  assert_eq(
    convert_error(base + "\noverrides:\n  deb:\n    nope: 1"),
    "overrides.deb.nope: unknown field",
  )
  assert_eq(
    convert_error(base + "\nplatform: windows"),
    "platform: \"windows\" is not supported, linuxpkg builds Linux packages",
  )
  assert_eq(convert_error(""), "the file is empty")
  assert_eq(convert_error("- a\n- b"), "the file must be a mapping")
  assert_true(convert_error("name: [unclosed").has_prefix("not valid YAML"))
  assert_eq(
    convert_error("version: 1\nmaintainer: x"),
    "name: package name must be provided",
  )
  assert_eq(
    convert_error("name: x\nmaintainer: x"),
    "version: package version must be provided",
  )
  let (_, warnings) = convert_ok(
    base +
    "\nchangelog: changelog.yaml\numask: 0o22\nrpm:\n  group: Unspecified\n  prefixes: [/usr]\n  scripts:\n    pretrans: pre.sh\n  requires:\n    post: [bash]\ndeb:\n  predepends: [dpkg]\n  breaks: [old]\n  fields:\n    Bugs: none\n  triggers:\n    interest: [x]\napk:\n  scripts:\n    preupgrade: u.sh\narchlinux:\n  pkgbase: x\nipk:\n  abi_version: \"1\"\n",
  )
  for
    expected in [
      "changelog: not supported", "umask: not used", "rpm.prefixes: not supported",
      "rpm.scripts.pretrans: not supported", "rpm.requires.post: not supported",
      "deb.predepends: not supported", "deb.breaks: not supported", "deb.fields: not supported",
      "deb.triggers: not supported", "apk.scripts.preupgrade: not supported", "archlinux.pkgbase: not supported",
      "ipk: linuxpkg does not build this format",
    ] {
    assert_true(warnings.any(w => w.has_prefix(expected)))
  }
  // The rpm group is the section.
  let (rpm_map, _) = convert_ok(
    base + "\nrpm:\n  group: Applications/System\n",
    format="rpm",
  )
  assert_eq(text_at(rpm_map, "section"), "Applications/System")
  // For one packager only its own settings are mentioned.
  let (_, deb_only) = convert_ok(
    base + "\nrpm:\n  group: g\ndeb:\n  breaks: [old]\n",
    format="deb",
  )
  assert_eq(deb_only.length(), 1)
  assert_true(deb_only[0].has_prefix("deb.breaks"))
  // An empty maintainer is replaced, with a warning.
  let (map, w) = convert_ok("name: x\nversion: 1")
  assert_eq(text_at(map, "maintainer"), "Unknown <unknown@example.invalid>")
  assert_true(w.any(m => m.has_prefix("maintainer is empty")))
}

///|
test "file types: config flavours, ghost, rpm flags, trees and globs" {
  let host = host_of([
    ("src/a.txt", b"a"),
    ("src/sub/b.txt", b"b"),
    ("src/sub/deep/c.txt", b"c"),
    ("only/one.txt", b"1"),
    ("x/f", b"f"),
    ("README", b"readme"),
    ("prog", b"\x7fELF\x02\x01\x01"),
    ("script", b"#!/bin/sh\n"),
    ("plain", b"text"),
  ])
  let yaml =
    #|name: x
    #|version: 1
    #|maintainer: "A <a@example.org>"
    #|contents:
    #|  - {src: x/f, dst: /etc/f.conf, type: config|noreplace}
    #|  - {src: x/f, dst: /etc/g.conf, type: config|missingok}
    #|  - {dst: /var/ghost, type: ghost}
    #|  - {src: README, dst: /usr/share/doc/x/README, type: doc}
    #|  - {src: src/*, dst: /opt/glob}
    #|  - {src: only/*, dst: /opt/flat}
    #|  - {src: src/sub/**/*.txt, dst: /opt/slash/}
    #|  - {src: src, dst: /opt/tree, type: tree}
    #|  - {src: x/f, dst: /opt/forced, file_info: {mode: 0o640, owner: u, group: g, mtime: "2024-02-29T12:30:15Z"}}
    #|  - {src: prog, dst: /usr/bin/prog}
    #|  - {src: script, dst: /usr/bin/script}
    #|  - {src: plain, dst: /usr/share/plain}
  let (map, warnings) = convert_ok(yaml, host~)
  let dsts = contents_of(map).map(c => text_at(c, "dst"))
  assert_eq(dsts, [
    "/etc/f.conf", "/etc/g.conf", "/usr/share/doc/x/README",
    // src/*: the matches are a.txt, sub, sub/b.txt, sub/deep, sub/deep/c.txt;
    // their common prefix is "src/", so paths are relative to "src".
     "/opt/glob/a.txt", "/opt/glob/sub/b.txt", "/opt/glob/sub/deep/c.txt",
    // only/*: one match, so the directory of the file is the base.
     "/opt/flat/one.txt",
    // a dst that ends in "/" gets the base names only; "**/" needs at least
    // one directory, so sub/b.txt is not matched.
     "/opt/slash/c.txt",
    // a tree: directories and files.
     "/opt/tree/a.txt", "/opt/tree/sub", "/opt/tree/sub/b.txt", "/opt/tree/sub/deep",
    "/opt/tree/sub/deep/c.txt", "/opt/forced", "/usr/bin/prog", "/usr/bin/script",
    "/usr/share/plain",
  ])
  let contents = contents_of(map)
  assert_eq(text_at(contents[0], "type"), "config")
  assert_eq(text_at(contents[13], "mode"), "0640")
  assert_eq(text_at(contents[13], "owner"), "u")
  assert_eq(text_at(contents[13], "group"), "g")
  assert_eq(text_at(contents[13], "mtime"), "1709209815")
  // Programs and scripts are executable, other files are not marked.
  assert_eq(text_at(contents[14], "mode"), "0755")
  assert_eq(text_at(contents[15], "mode"), "0755")
  assert_eq(text_at(contents[16], "mode"), "<none>")
  for
    expected in [
      "contents[1]: \"missingok\" is not supported", "contents[2]: ghost files are not supported",
      "contents[3]: type \"doc\" is an rpm file flag", "contents[7]: symbolic links inside a tree",
    ] {
    assert_true(warnings.any(w => w.has_prefix(expected)))
  }
  // The rpm flag types are left out of the other formats without a word.
  let (deb, deb_warnings) = convert_ok(yaml, host~, format="deb")
  assert_false(
    contents_of(deb).any(c => text_at(c, "dst") == "/usr/share/doc/x/README"),
  )
  assert_false(deb_warnings.any(w => w.contains("\"doc\"")))
}

///|
test "globs: no match, plain directory, disable_globbing" {
  let host = host_of([("dir/a", b"a"), ("dir/b/c", b"c"), ("lit*eral", b"x")])
  let base =
    #|name: x
    #|version: 1
    #|maintainer: "A <a@example.org>"
    #|contents:
  assert_eq(
    convert_error(base + "\n  - {src: nothing/*, dst: /x}", host~),
    "glob failed: nothing/*: no matching files",
  )
  // A plain file with a destination that ends in "/" goes into that directory,
  // a destination without the slash is the file itself.
  let (into, _) = convert_ok(
    base +
    "\n  - {src: dir/a, dst: /usr/share/doc/x/}\n  - {src: dir/a, dst: /usr/share/doc/y}",
    host~,
  )
  assert_eq(contents_of(into).map(c => text_at(c, "dst")), [
    "/usr/share/doc/x/a", "/usr/share/doc/y",
  ])
  // A directory as src: everything in it, relative to it.
  let (dir, _) = convert_ok(base + "\n  - {src: dir, dst: /opt/d}", host~)
  assert_eq(contents_of(dir).map(c => text_at(c, "dst")), [
    "/opt/d/a", "/opt/d/b/c",
  ])
  // With disable_globbing the star is part of the name.
  let (lit, _) = convert_ok(
    base + "\n  - {src: lit*eral, dst: /opt/lit}\ndisable_globbing: true",
    host~,
  )
  assert_eq(contents_of(lit).map(c => text_at(c, "src")), ["lit*eral"])
  assert_eq(contents_of(lit).map(c => text_at(c, "dst")), ["/opt/lit"])
  assert_eq(
    convert_error(
      base + "\n  - {src: dir, dst: /x, type: tree}",
      host=host_of([]),
    ),
    "contents[0].src: \"dir\" is not a directory (or cannot be read here)",
  )
  assert_eq(
    convert_error(base + "\n  - {dst: /x}"),
    "contents[0].src: is required for a file",
  )
  assert_eq(
    convert_error(base + "\n  - {src: a}"),
    "contents[0].dst: is required",
  )
  assert_eq(
    convert_error(base + "\n  - {src: a, dst: /x, type: weird}"),
    "contents[0].type: invalid content type \"weird\"",
  )
  assert_eq(
    convert_error(base + "\n  - {src: a, dst: /x, file_info: {mode: 0789}}"),
    "contents[0].file_info.mode: mode must be octal, for example 0755 (hexadecimal and decimal modes are not supported)",
  )
}

///|
test "signing keys, compression and times" {
  let yaml =
    #|name: x
    #|version: 1
    #|maintainer: "A <a@example.org>"
    #|mtime: "2024-02-29"
    #|deb:
    #|  compression: zstd
    #|  signature:
    #|    key_file: deb.key
    #|rpm:
    #|  compression: xz
    #|  signature:
    #|    key_file: $KEYDIR/rpm.key
    #|    key_id: abc
    #|apk:
    #|  signature:
    #|    key_file: $KEYDIR/rpm.key
    #|    key_name: my.rsa.pub
  let host = host_of([], env=[("KEYDIR", "keys"), ("NFPM_PASSPHRASE", "secret")])
  let (map, warnings) = convert_ok(yaml, host~)
  assert_eq(text_at(map, "sign_key"), "keys/rpm.key")
  assert_eq(text_at(map, "apk_key_name"), "my.rsa.pub")
  assert_eq(text_at(map, "mtime"), "1709164800")
  assert_eq(
    map.get("deb"),
    Some(Json::object({ "compression": Json::string("zstd") })),
  )
  assert_eq(
    map.get("rpm"),
    Some(Json::object({ "compression": Json::string("xz") })),
  )
  assert_true(
    warnings.any(w => w.has_prefix("deb.signature: deb packages are not signed")),
  )
  assert_true(warnings.any(w => w.has_prefix("rpm.signature.key_id")))
  assert_true(warnings.any(w => w.has_prefix("NFPM_PASSPHRASE")))
  // For deb alone there is nothing to sign with.
  let (deb, _) = convert_ok(yaml, host~, format="deb")
  assert_eq(deb.get("sign_key"), None)
  assert_eq(deb.get("rpm"), None)
  assert_true(
    convert_error(
      "name: x\nversion: 1\nrpm:\n  compression: lzma",
      format="rpm",
    ).contains("lzma is not supported for writing"),
  )
  assert_true(
    convert_error("name: x\nversion: 1\nmtime: soon").contains("not a time"),
  )
  // epoch and release may be numbers.
  let (numbers, _) = convert_ok(
    "name: x\nversion: 1\nepoch: 2\nrelease: 3\nmaintainer: \"A <a@example.org>\"",
  )
  assert_eq(text_at(numbers, "epoch"), "2")
  assert_eq(text_at(numbers, "release"), "3")
  assert_true(
    convert_error("name: x\nversion: 1\nepoch: abc").contains(
      "epoch: must be a whole number",
    ),
  )
}
