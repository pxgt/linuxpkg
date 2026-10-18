///|
test "architecture names map between deb and rpm" {
  let table = [
    (@spec.Arch::Amd64, "amd64", "x86_64"),
    (@spec.Arch::Arm64, "arm64", "aarch64"),
    (@spec.Arch::I386, "i386", "i686"),
    (@spec.Arch::Armhf, "armhf", "armv7hl"),
    (@spec.Arch::Armel, "armel", "armv5tel"),
    (@spec.Arch::Ppc64le, "ppc64el", "ppc64le"),
    (@spec.Arch::S390x, "s390x", "s390x"),
    (@spec.Arch::Riscv64, "riscv64", "riscv64"),
    (@spec.Arch::Loong64, "loong64", "loongarch64"),
    (@spec.Arch::Mips64le, "mips64el", "mips64el"),
    (@spec.Arch::All, "all", "noarch"),
  ]
  for entry in table {
    let (arch, deb, rpm) = entry
    assert_eq(arch.deb_name(), deb)
    assert_eq(arch.rpm_name(), rpm)
    // Both spellings parse back to the same architecture.
    assert_eq(@spec.Arch::parse(deb), arch)
    assert_eq(@spec.Arch::parse(rpm), arch)
  }
}

///|
test "architecture aliases" {
  assert_eq(@spec.Arch::parse("x64"), @spec.Arch::Amd64)
  assert_eq(@spec.Arch::parse("aarch64"), @spec.Arch::Arm64)
  assert_eq(@spec.Arch::parse("386"), @spec.Arch::I386)
  assert_eq(@spec.Arch::parse("x86"), @spec.Arch::I386)
  assert_eq(@spec.Arch::parse("armv7"), @spec.Arch::Armhf)
  assert_eq(@spec.Arch::parse("ppc64le"), @spec.Arch::Ppc64le)
  assert_eq(@spec.Arch::parse("noarch"), @spec.Arch::All)
}

///|
test "unknown architecture is rejected" {
  try @spec.Arch::parse("sparc") catch {
    err =>
      inspect(
        "\{err}",
        content="arch: unknown architecture \"sparc\" (try amd64, arm64, i386, armhf, armel, ppc64le, s390x, riscv64, loong64, mips64le or all)",
      )
  } noraise {
    _ => fail("expected an error")
  }
}
