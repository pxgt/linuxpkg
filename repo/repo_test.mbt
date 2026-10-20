///|
fn spec_of(
  name : String,
  version : String,
  arch : @spec.Arch,
  depends~ : Array[@spec.Dependency] = [],
) -> @spec.PackageSpec raise {
  @spec.PackageSpec::new(
    name~,
    version~,
    arch~,
    maintainer="Jane <jane@example.org>",
    description="Package \{name}\nSecond line & <more>.",
    homepage="https://example.org/\{name}",
    license="MIT",
    depends~,
    provides=[@spec.Dependency::parse("\{name}-api = 2")],
    entries=[
      @spec.Entry::file(
        "/usr/bin/\{name}",
        b"#!/bin/sh\necho \{name}\n",
        mode=0o755,
      ),
      @spec.Entry::file("/etc/\{name}.conf", b"x=1\n", config=true),
      @spec.Entry::file("/usr/share/\{name}/data.txt", b"data\n"),
    ],
    mtime=1700000000L,
  )
}

///|
fn debs() -> Array[@repo.PackageFile] raise {
  [
    {
      name: "beta_2.0-1_amd64.deb",
      data: @deb.build(
        spec_of("beta", "2.0", Amd64, depends=[
          @spec.Dependency::parse("alpha (>= 1.0)"),
        ]),
      ),
    },
    {
      name: "alpha_1.0-1_all.deb",
      data: @deb.build(spec_of("alpha", "1.0", All), compression=Xz),
    },
  ]
}

///|
fn rpms() -> Array[@repo.PackageFile] raise {
  [
    {
      name: "beta-2.0-1.x86_64.rpm",
      data: @rpm.build(
        spec_of("beta", "2.0", Amd64, depends=[
          @spec.Dependency::parse("alpha >= 1.0"),
        ]),
      ),
    },
    {
      name: "alpha-1.0-1.noarch.rpm",
      data: @rpm.build(spec_of("alpha", "1.0", All), compression=Zstd),
    },
  ]
}

///|
test "rfc2822 dates" {
  inspect(@repo.rfc2822(0L), content="Thu, 01 Jan 1970 00:00:00 +0000")
  inspect(@repo.rfc2822(1700000000L), content="Tue, 14 Nov 2023 22:13:20 +0000")
  inspect(@repo.rfc2822(951782400L), content="Tue, 29 Feb 2000 00:00:00 +0000")
  inspect(@repo.rfc2822(4102444799L), content="Thu, 31 Dec 2099 23:59:59 +0000")
  inspect(@repo.rfc2822(-1L), content="Wed, 31 Dec 1969 23:59:59 +0000")
}

///|
test "apt index: files, order and fields" {
  let files = @repo.apt_index(debs(), date=1700000000L)
  assert_eq(files.map(f => f.0), [
    "Packages", "Packages.gz", "Packages.xz", "Release",
  ])
  let packages = @utf8.decode_lossy(files[0].1)
  // Sorted by file name: alpha first.
  assert_true(packages.has_prefix("Package: alpha\nVersion: 1.0-1\n"))
  let alpha = packages.find("Package: alpha").unwrap()
  let beta = packages.find("Package: beta").unwrap()
  assert_true(alpha < beta)
  assert_true(packages.contains("Filename: ./alpha_1.0-1_all.deb\n"))
  assert_true(packages.contains("Filename: ./beta_2.0-1_amd64.deb\n"))
  assert_true(packages.contains("Depends: alpha (>= 1.0)\n"))
  assert_true(packages.has_suffix("\n\n"))
  let release = @utf8.decode_lossy(files[3].1)
  assert_true(
    release.has_prefix(
      "Date: Tue, 14 Nov 2023 22:13:20 +0000\nArchitectures: all amd64\nMD5Sum:\n",
    ),
  )
  assert_true(release.contains("\nSHA1:\n"))
  assert_true(release.contains("\nSHA256:\n"))
  assert_eq(@repo.check_apt(files, debs()), [])
}

///|
test "apt index is deterministic and independent of input order" {
  let a = @repo.apt_index(debs(), date=5L)
  let reversed = debs()
  reversed.rev_in_place()
  let b = @repo.apt_index(reversed, date=5L)
  assert_eq(a, b)
  let c = @repo.apt_index(debs(), date=6L)
  assert_true(a[3].1 != c[3].1)
}

///|
test "apt index of nothing is empty but consistent" {
  let files = @repo.apt_index([], date=0L)
  assert_eq(files[0].1, b"")
  assert_eq(@repo.check_apt(files, []), [])
}

///|
test "apt index rejects bad input" {
  let bad : Array[(Array[@repo.PackageFile], String)] = [
    ([{ name: "x.deb", data: b"not a deb", }], "x.deb:"),
    ([{ name: "x.txt", data: b"", }], "x.txt: the name must end with .deb"),
    (
      [{ name: "a b.deb", data: b"", }],
      "a b.deb: the name must be a plain file name without spaces or slashes",
    ),
  ]
  for item in bad {
    try @repo.apt_index(item.0, date=0L) catch {
      err => assert_true("\{err}".has_prefix(item.1))
    } noraise {
      _ => fail("expected an error for \{item.1}")
    }
  }
  let twice = debs()
  twice.push(twice[0])
  try @repo.apt_index(twice, date=0L) catch {
    err =>
      inspect(
        "\{err}",
        content="beta_2.0-1_amd64.deb: the file name is used twice",
      )
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "check_apt finds every kind of damage" {
  let given = debs()
  let files = @repo.apt_index(given, date=1700000000L)
  let damaged = (name : String, change : (Bytes) -> Bytes) => {
    files.map(f => if f.0 == name { (f.0, change(f.1)) } else { f })
  }
  let flip = (data : Bytes) => {
    let copy = data.to_fixedarray()
    copy[0] = (copy[0].to_int() ^ 1).to_byte()
    Bytes::from_array(copy[:])
  }
  assert_true(@repo.check_apt(damaged("Packages", flip), given).length() > 0)
  assert_true(@repo.check_apt(damaged("Packages.gz", flip), given).length() > 0)
  assert_true(@repo.check_apt(damaged("Packages.xz", flip), given).length() > 0)
  assert_true(@repo.check_apt(damaged("Release", flip), given).length() > 0)
  assert_true(
    @repo.check_apt(damaged("Packages", _ => b""), given).length() > 0,
  )
  // A deb that changed after the index was made.
  let changed = given.copy()
  changed[0] = { name: given[0].name, data: flip(given[0].data), }
  assert_true(@repo.check_apt(files, changed).length() > 0)
  // A deb the index does not know.
  let more = given.copy()
  more.push({ name: "gamma_1_all.deb", data: given[0].data, })
  let missing = @repo.check_apt(files, more)
  assert_true(missing.any(p => p.contains("does not list gamma_1_all.deb")))
  // Missing files.
  assert_eq(@repo.check_apt([], given), ["Release is missing"])
  let no_packages = files.filter(f => f.0 != "Packages")
  assert_true(
    @repo.check_apt(no_packages, given).any(p => p == "Packages is missing"),
  )
  let no_gz = files.filter(f => f.0 != "Packages.gz")
  assert_true(
    @repo.check_apt(no_gz, given).any(p => p == "Packages.gz is missing"),
  )
}

///|
test "yum index: layout and content" {
  let files = @repo.yum_index(rpms(), timestamp=1700000000L)
  assert_eq(files.length(), 4)
  assert_eq(files[3].0, "repodata/repomd.xml")
  let names = files.map(f => f.0)
  assert_true(names[0].has_suffix("-primary.xml.gz"))
  assert_true(names[1].has_suffix("-filelists.xml.gz"))
  assert_true(names[2].has_suffix("-other.xml.gz"))
  let repomd = @utf8.decode_lossy(files[3].1)
  assert_true(repomd.contains("<revision>1700000000</revision>"))
  assert_true(repomd.contains("<data type=\"primary\">"))
  let primary = @utf8.decode_lossy(@compress.decompress(files[0].1, Gzip))
  assert_true(primary.contains("packages=\"2\""))
  assert_true(primary.contains("<name>alpha</name>\n  <arch>noarch</arch>"))
  assert_true(primary.contains("<name>beta</name>\n  <arch>x86_64</arch>"))
  assert_true(primary.contains("<location href=\"alpha-1.0-1.noarch.rpm\"/>"))
  // Escaping of the description.
  assert_true(primary.contains("Second line &amp; &lt;more&gt;."))
  // Relations: provides, requires with a version, no rpmlib entries.
  assert_true(
    primary.contains(
      "<rpm:entry name=\"alpha-api\" flags=\"EQ\" epoch=\"0\" ver=\"2\"/>",
    ),
  )
  assert_true(
    primary.contains(
      "<rpm:entry name=\"alpha\" flags=\"GE\" epoch=\"0\" ver=\"1.0\"/>",
    ),
  )
  assert_true(!primary.contains("rpmlib("))
  // Only executables and configuration are in primary, everything is in filelists.
  assert_true(primary.contains("<file>/usr/bin/alpha</file>"))
  assert_true(primary.contains("<file>/etc/alpha.conf</file>"))
  assert_true(!primary.contains("/usr/share/alpha/data.txt"))
  let filelists = @utf8.decode_lossy(@compress.decompress(files[1].1, Gzip))
  assert_true(filelists.contains("<file>/usr/share/alpha/data.txt</file>"))
  assert_eq(@repo.check_yum(files, rpms()), [])
}

///|
test "yum index is deterministic and independent of input order" {
  let a = @repo.yum_index(rpms(), timestamp=7L)
  let reversed = rpms()
  reversed.rev_in_place()
  assert_eq(a, @repo.yum_index(reversed, timestamp=7L))
  assert_true(a != @repo.yum_index(rpms(), timestamp=8L))
}

///|
test "yum index of nothing is consistent" {
  let files = @repo.yum_index([], timestamp=0L)
  assert_eq(@repo.check_yum(files, []), [])
}

///|
test "yum index rejects bad input" {
  try @repo.yum_index([{ name: "x.rpm", data: b"nope", }], timestamp=0L) catch {
    err => assert_true("\{err}".has_prefix("x.rpm:"))
  } noraise {
    _ => fail("expected an error")
  }
  try @repo.yum_index([{ name: "x.deb", data: b"", }], timestamp=0L) catch {
    err => inspect("\{err}", content="x.deb: the name must end with .rpm")
  } noraise {
    _ => fail("expected an error")
  }
}

///|
test "check_yum finds every kind of damage" {
  let given = rpms()
  let files = @repo.yum_index(given, timestamp=1700000000L)
  let flip = (data : Bytes) => {
    let copy = data.to_fixedarray()
    copy[copy.length() / 2] = (copy[copy.length() / 2].to_int() ^ 1).to_byte()
    Bytes::from_array(copy[:])
  }
  for i in 0..<4 {
    let damaged = files.mapi((j, f) => if i == j { (f.0, flip(f.1)) } else { f })
    assert_true(@repo.check_yum(damaged, given).length() > 0)
  }
  let changed = given.copy()
  changed[0] = { name: given[0].name, data: flip(given[0].data), }
  assert_true(@repo.check_yum(files, changed).length() > 0)
  let more = given.copy()
  more.push({ name: "gamma-1-1.noarch.rpm", data: given[0].data, })
  assert_true(
    @repo.check_yum(files, more).any(p => p.contains("does not list gamma")),
  )
  assert_eq(@repo.check_yum([], given), ["repodata/repomd.xml is missing"])
  let no_primary = files.filter(f => !f.0.has_suffix("-primary.xml.gz"))
  assert_true(@repo.check_yum(no_primary, given).length() > 0)
}

///|
test "times" {
  assert_eq(@repo.rpm_time(rpms()[0]), 1700000000L)
  assert_eq(@repo.deb_time(debs()[0]), 1700000000L)
}
