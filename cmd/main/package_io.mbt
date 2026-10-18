///|
/// A package file opened for inspection or verification.
priv enum Package {
  Deb(@deb.DebPackage)
  Rpm(@rpm.RpmPackage)
}

///|
/// Turn a package library error into the matching CLI error. A damaged but
/// recognizable package is an integrity failure (`Mismatch`, exit 2), anything
/// else (unsupported features, bad input) a plain failure (exit 1).
fn rpm_failure(path : String, err : @rpm.RpmError) -> CliError {
  match err {
    Corrupt(..) => Mismatch("\{path}: \{err}")
    _ => Failed("\{path}: \{err}")
  }
}

///|
/// Load a package and tell its format from the first bytes.
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
    let rpm = @rpm.read(data) catch { err => raise rpm_failure(path, err) }
    return Rpm(rpm)
  }
  raise Failed("\{path}: not a deb or rpm package")
}

///|
fn Package::report(self : Package, path : String) -> Json raise CliError {
  match self {
    Deb(deb) => deb.to_json()
    Rpm(rpm) => rpm.to_json() catch { err => raise rpm_failure(path, err) }
  }
}

///|
/// Integrity problems, one per line; empty when the package is sound.
fn Package::problems(
  self : Package,
  path : String,
) -> Array[String] raise CliError {
  match self {
    Deb(deb) => deb.verify()
    Rpm(rpm) => rpm.verify() catch { err => raise rpm_failure(path, err) }
  }
}

///|
/// How many checksums `problems` compared.
fn Package::checked_files(self : Package) -> Int32 {
  match self {
    Deb(deb) => deb.md5sums.length()
    Rpm(rpm) => {
      let mut count = 0
      for digest in rpm.header.strings(1035) {
        if digest != "" {
          count += 1
        }
      }
      count
    }
  }
}
