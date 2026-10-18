///|
fn sample(
  entries~ : Array[@spec.Entry] = [],
  description~ : String = "Says hello\nA longer text.",
) -> @spec.PackageSpec {
  @spec.PackageSpec::new(
    name="hello",
    version="1.0.0",
    arch=@spec.Arch::Amd64,
    maintainer="Jane <jane@example.org>",
    description~,
    entries~,
  )
}

///|
fn verdict(spec : @spec.PackageSpec) -> String {
  try spec.validate() catch {
    err => "\{err}"
  } noraise {
    _ => "ok"
  }
}

///|
test "a complete spec is valid" {
  let spec = @spec.PackageSpec::new(
    name="hello",
    version="1.2.3~rc1",
    release="2",
    epoch=1,
    arch=@spec.Arch::Arm64,
    maintainer="Jane <jane@example.org>",
    description="Says hello\n\nA longer text.\nWith lines.",
    homepage="https://example.org/hello",
    license="Apache-2.0",
    vendor="Example",
    section="utils",
    priority="optional",
    depends=[@spec.Dependency::parse("libc6 (>= 2.31)")],
    entries=[
      @spec.Entry::dir("/usr"),
      @spec.Entry::dir("/usr/bin"),
      @spec.Entry::file("/usr/bin/hello", b"#!/bin/sh\n", mode=0o755),
      @spec.Entry::symlink("/usr/bin/hi", "hello"),
      @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true),
    ],
    scripts={
      pre_install: None,
      post_install: Some("#!/bin/sh\nexit 0\n"),
      pre_remove: None,
      post_remove: None,
    },
    mtime=1700000000L,
  )
  inspect(verdict(spec), content="ok")
}

///|
test "identity fields" {
  let base = sample()
  inspect(
    verdict({ ..base, name: "Hello", }),
    content="name: must be lowercase",
  )
  inspect(
    verdict({ ..base, version: "x", }),
    content="version: must start with a digit",
  )
  inspect(
    verdict({ ..base, release: "", }),
    content="release: must not be empty",
  )
  inspect(
    verdict({ ..base, epoch: -1, }),
    content="epoch: must be between 0 and 2147483647",
  )
  inspect(
    verdict({ ..base, maintainer: "  ", }),
    content="maintainer: must not be empty",
  )
  inspect(
    verdict({ ..base, maintainer: "Jane\nDoe", }),
    content="maintainer: must be a single line without control characters",
  )
  inspect(
    verdict({ ..base, mtime: -5L, }),
    content="mtime: must not be negative",
  )
}

///|
test "descriptive fields" {
  inspect(
    verdict(sample(description="")),
    content="description: must not be empty",
  )
  inspect(
    verdict(sample(description="\nonly a body")),
    content="description: the first line (summary) must not be empty",
  )
  inspect(
    verdict(sample(description="bad\u{7}bell")),
    content="description: must not contain control characters",
  )
  let base = sample()
  inspect(
    verdict({ ..base, homepage: Some("not a url"), }),
    content="homepage: must not contain spaces or control characters",
  )
  inspect(
    verdict({ ..base, homepage: Some(""), }),
    content="homepage: must not be empty",
  )
  inspect(
    verdict({ ..base, license: Some(""), }),
    content="license: must not be empty",
  )
  inspect(
    verdict({ ..base, section: "a b", }),
    content="section: contains \" \", only letters, digits, '/', '_', '.', '+' and '-' are allowed",
  )
  inspect(
    verdict({ ..base, priority: "urgent", }),
    content="priority: must be one of required, important, standard, optional or extra",
  )
}

///|
test "relations are checked with their position" {
  let base = sample()
  inspect(
    verdict({
      ..base,
      conflicts: [
        { name: "ok", constraint: None, },
        { name: "", constraint: None, },
      ],
    }),
    content="conflicts[1]: package name must not be empty",
  )
}

///|
test "entries are checked with their position" {
  inspect(
    verdict(sample(entries=[@spec.Entry::file("usr/bin/hello", b"")])),
    content="entries[0].path: must be an absolute path starting with '/'",
  )
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::dir("/usr"),
        @spec.Entry::file("/usr/bin/hello", b"", mode=0o10000),
      ]),
    ),
    content="entries[1].mode: must be between 0 and 07777 (octal), got 10000",
  )
  inspect(
    verdict(sample(entries=[@spec.Entry::file("/a/b", b"", owner="")])),
    content="entries[0].owner: must be 1 to 32 characters long",
  )
  inspect(
    verdict(sample(entries=[@spec.Entry::symlink("/a/link", "")])),
    content="entries[0].target: must not be empty",
  )
  inspect(
    verdict(sample(entries=[@spec.Entry::file("/a/b", b"", mtime=-1L)])),
    content="entries[0].mtime: must not be negative",
  )
  inspect(
    verdict(sample(entries=[{ ..@spec.Entry::dir("/opt/x"), config: true, }])),
    content="entries[0].config: a directory cannot be a config file",
  )
}

///|
test "duplicate paths are rejected" {
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::file("/usr/bin/hello", b"a"),
        @spec.Entry::file("/usr/bin/hello", b"b"),
      ]),
    ),
    content="entries[1].path: \"/usr/bin/hello\" is already used by entries[0]",
  )
}

///|
test "nothing may be installed below a file or a link" {
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::file("/usr/bin/hello", b"a"),
        @spec.Entry::file("/usr/bin/hello/extra", b"b"),
      ]),
    ),
    content="entries[1].path: \"/usr/bin/hello/extra\" would be installed below \"/usr/bin/hello\", which entries[0] makes a file or a symbolic link",
  )
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::symlink("/usr/lib64", "lib"),
        @spec.Entry::file("/usr/lib64/libx.so", b"b"),
      ]),
    ),
    content="entries[1].path: \"/usr/lib64/libx.so\" would be installed below \"/usr/lib64\", which entries[0] makes a file or a symbolic link",
  )
  // Directories may of course contain files.
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::dir("/usr/share/hello"),
        @spec.Entry::file("/usr/share/hello/README", b"b"),
      ]),
    ),
    content="ok",
  )
  // A file whose name merely starts like another path is fine.
  inspect(
    verdict(
      sample(entries=[
        @spec.Entry::file("/usr/bin/hello", b"a"),
        @spec.Entry::file("/usr/bin/hello2", b"b"),
      ]),
    ),
    content="ok",
  )
}

///|
test "scripts" {
  let base = sample()
  inspect(
    verdict({
      ..base,
      scripts: { ..@spec.Scripts::empty(), post_install: Some(""), },
    }),
    content="scripts.post_install: must not be empty, omit it instead",
  )
  inspect(
    verdict({
      ..base,
      scripts: { ..@spec.Scripts::empty(), pre_remove: Some("a\u{0}b"), },
    }),
    content="scripts.pre_remove: must not contain NUL characters",
  )
}
