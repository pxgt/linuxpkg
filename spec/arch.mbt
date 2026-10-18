///|
/// CPU architectures shared by deb and rpm. The same value has a different
/// spelling in each ecosystem, see `Arch::deb_name` and `Arch::rpm_name`.
pub(all) enum Arch {
  Amd64
  Arm64
  I386
  Armhf
  Armel
  Ppc64le
  S390x
  Riscv64
  Loong64
  Mips64le
  All
} derive(Eq, Debug)

///|
/// Parse an architecture written the Debian way (`amd64`), the RPM way
/// (`x86_64`) or the Go way (`386`). `all` and `noarch` both mean
/// architecture independent.
///
/// # Example
/// ```mbt check
/// test {
///   assert_eq(@spec.Arch::parse("x86_64"), @spec.Arch::Amd64)
///   assert_eq(@spec.Arch::parse("noarch"), @spec.Arch::All)
/// }
/// ```
pub fn Arch::parse(text : String) -> Arch raise SpecError {
  match text {
    "amd64" | "x86_64" | "x64" => Amd64
    "arm64" | "aarch64" => Arm64
    "i386" | "386" | "i686" | "x86" => I386
    "armhf" | "armv7" | "armv7hl" => Armhf
    "armel" | "armv5tel" => Armel
    "ppc64le" | "ppc64el" => Ppc64le
    "s390x" => S390x
    "riscv64" => Riscv64
    "loong64" | "loongarch64" => Loong64
    "mips64le" | "mips64el" => Mips64le
    "all" | "noarch" => All
    _ =>
      raise invalid(
        "arch",
        "unknown architecture \"\{text}\" (try amd64, arm64, i386, armhf, armel, ppc64le, s390x, riscv64, loong64, mips64le or all)",
      )
  }
}

///|
/// The name Debian tools use, for example `amd64` or `all`.
pub fn Arch::deb_name(self : Arch) -> String {
  match self {
    Amd64 => "amd64"
    Arm64 => "arm64"
    I386 => "i386"
    Armhf => "armhf"
    Armel => "armel"
    Ppc64le => "ppc64el"
    S390x => "s390x"
    Riscv64 => "riscv64"
    Loong64 => "loong64"
    Mips64le => "mips64el"
    All => "all"
  }
}

///|
/// The name RPM tools use, for example `x86_64` or `noarch`.
pub fn Arch::rpm_name(self : Arch) -> String {
  match self {
    Amd64 => "x86_64"
    Arm64 => "aarch64"
    I386 => "i686"
    Armhf => "armv7hl"
    Armel => "armv5tel"
    Ppc64le => "ppc64le"
    S390x => "s390x"
    Riscv64 => "riscv64"
    Loong64 => "loongarch64"
    Mips64le => "mips64el"
    All => "noarch"
  }
}
