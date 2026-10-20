///|
/// A package file opened for inspection or verification.
priv enum Package {
  Deb(@deb.DebPackage)
  Rpm(@rpm.RpmPackage)
  Arch(@arch.ArchPackage)
  Apk(@apk.ApkPackage)
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
  // Alpine packages are two or three gzip streams in a row. An Arch Linux
  // package compressed with gzip is a single stream, so try apk first.
  if data.length() >= 2 && data[0:2] == b"\x1f\x8b"[:] {
    try @apk.read(data) catch {
      @apk.ApkError::Corrupt(message~) =>
        if path.has_suffix(".apk") {
          raise Mismatch("\{path}: \{message}")
        }
      err => if path.has_suffix(".apk") { raise Failed("\{path}: \{err}") }
    } noraise {
      apk => return Apk(apk)
    }
  }
  // Arch Linux packages are plain, zstd, xz or gzip compressed tar files.
  let looks_arch = path.contains(".pkg.tar")
  let arch = @arch.read(data) catch {
    @arch.ArchError::Corrupt(message~) =>
      if looks_arch && !message.contains("no .PKGINFO") {
        raise Mismatch("\{path}: \{message}")
      } else {
        raise Failed("\{path}: not a deb, rpm, apk or Arch Linux package")
      }
    err => raise Failed("\{path}: \{err}")
  }
  Arch(arch)
}

///|
fn Package::report(self : Package, path : String) -> Json raise CliError {
  match self {
    Deb(deb) => deb.to_json()
    Rpm(rpm) => rpm.to_json() catch { err => raise rpm_failure(path, err) }
    Arch(arch) => arch.to_json()
    Apk(apk) => apk.to_json()
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
    Arch(arch) => arch.verify()
    Apk(apk) => apk.verify()
  }
}

///|
/// How many checksums `problems` compared.
fn Package::checked_files(self : Package) -> Int32 {
  match self {
    Deb(deb) => deb.md5sums.length()
    Arch(arch) => arch.checked_files()
    Apk(apk) => apk.checked_files()
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
