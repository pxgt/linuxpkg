///|
/// A package file opened for inspection or verification.
priv enum Package {
  Deb(@deb.DebPackage)
}

///|
/// Load a package and tell its format from the first bytes. A damaged but
/// recognizable package raises `Mismatch` (integrity failure), a file that is
/// not a package or uses an unsupported feature raises `Failed`.
fn load_package(path : String) -> Package raise CliError {
  let data = read_bytes(path)
  if data.length() >= 8 && data[0:8] == b"!<arch>\n"[:] {
    let deb = @deb.read(data) catch {
      Corrupt(message~) => raise Mismatch("\{path}: \{message}")
      err => raise Failed("\{path}: \{err}")
    }
    return Deb(deb)
  }
  if data.length() >= 4 && data[0:4] == b"\xed\xab\xee\xdb"[:] {
    raise Failed("\{path}: rpm files are not supported yet")
  }
  raise Failed("\{path}: not a deb or rpm package")
}

///|
fn Package::report(self : Package) -> Json {
  match self {
    Deb(deb) => deb.to_json()
  }
}

///|
/// Integrity problems, one per line; empty when the package is sound.
fn Package::problems(self : Package) -> Array[String] {
  match self {
    Deb(deb) => deb.verify()
  }
}

///|
/// How many files carry a checksum that `problems` compared.
fn Package::checked_files(self : Package) -> Int32 {
  match self {
    Deb(deb) => deb.md5sums.length()
  }
}
