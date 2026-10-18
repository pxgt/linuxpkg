///|
test "entry constructors apply the documented defaults" {
  let file = @spec.Entry::file("/usr/bin/hello", b"echo hi\n")
  assert_eq(file.mode, 0o644)
  assert_eq(file.owner, "root")
  assert_eq(file.group, "root")
  assert_eq(file.mtime, None)
  assert_eq(file.config, false)
  assert_eq(file.kind, @spec.EntryKind::File(b"echo hi\n"))
  let script = @spec.Entry::file("/usr/bin/run", b"#!/bin/sh\n", mode=0o755)
  assert_eq(script.mode, 0o755)
  let conf = @spec.Entry::file("/etc/hello.conf", b"x=1\n", config=true)
  assert_eq(conf.config, true)
  let dir = @spec.Entry::dir("/var/lib/hello")
  assert_eq(dir.kind, @spec.EntryKind::Dir)
  assert_eq(dir.mode, 0o755)
  let link = @spec.Entry::symlink("/usr/bin/hi", "hello")
  assert_eq(link.kind, @spec.EntryKind::Symlink("hello"))
  assert_eq(link.mode, 0o777)
}

///|
test "package spec defaults" {
  let spec = @spec.PackageSpec::new(
    name="hello",
    version="1.0.0",
    arch=@spec.Arch::Amd64,
    maintainer="Jane <jane@example.org>",
    description="Says hello",
  )
  assert_eq(spec.release, "1")
  assert_eq(spec.epoch, 0)
  assert_eq(spec.section, "misc")
  assert_eq(spec.priority, "optional")
  assert_eq(spec.mtime, 0L)
  assert_eq(spec.entries.length(), 0)
  assert_eq(spec.scripts, @spec.Scripts::empty())
}
