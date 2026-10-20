///|
fn hex(bytes : FixedArray[Byte]) -> String {
  @crypto.bytes_to_hex_string(bytes)
}

///|
fn md5_hex(data : Bytes) -> String {
  hex(@crypto.md5(data))
}

///|
fn sha1_hex(data : Bytes) -> String {
  hex(@crypto.sha1(data))
}

///|
fn sha256_hex(data : Bytes) -> String {
  hex(@crypto.sha256(data))
}

///|
let weekdays : Array[String] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

///|
let months : Array[String] = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

///|
fn pad2(n : Int32) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
/// A Unix time as an RFC 2822 date in UTC, the format of the `Date` field of
/// a `Release` file: `Tue, 20 Oct 2026 08:36:46 +0000`.
pub fn rfc2822(seconds : Int64) -> String {
  let day_seconds = 86400L
  let mut days = seconds / day_seconds
  let mut rest = seconds % day_seconds
  if rest < 0L {
    rest += day_seconds
    days -= 1L
  }
  let weekday = ((days + 4L) % 7L + 7L) % 7L
  // Civil date from the day count (Howard Hinnant's algorithm).
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let day = (doy - (153L * mp + 2L) / 5L + 1L).to_int()
  let month = (if mp < 10L { mp + 3L } else { mp - 9L }).to_int()
  let year = (yoe + era * 400L + (if month <= 2 { 1L } else { 0L })).to_int()
  let hour = (rest / 3600L).to_int()
  let minute = (rest % 3600L / 60L).to_int()
  let second = (rest % 60L).to_int()
  "\{weekdays[weekday.to_int()]}, \{pad2(day)} \{months[month - 1]} \{year} \{pad2(hour)}:\{pad2(minute)}:\{pad2(second)} +0000"
}

///|
/// The `control` file of a deb, without trailing blank lines, and its
/// architecture.
fn control_text(file : PackageFile) -> (String, String) raise RepoError {
  let pkg = @deb.read(file.data) catch {
    err => raise RepoError::Invalid(file=file.name, message="\{err}")
  }
  for pair in pkg.control_files {
    if pair.0 == "control" {
      let text = @utf8.decode_lossy(pair.1)
      let mut end = text.length()
      while end > 0 && (text[end - 1] == '\n' || text[end - 1] == '\r') {
        end -= 1
      }
      for field in ["Package", "Version", "Architecture"] {
        if pkg.field(field) is None {
          raise RepoError::Invalid(
            file=file.name,
            message="the control file has no \{field} field",
          )
        }
      }
      for field in ["Filename", "Size", "MD5sum", "SHA1", "SHA256"] {
        if pkg.field(field) is Some(_) {
          raise RepoError::Invalid(
            file=file.name,
            message="the control file already has a \{field} field",
          )
        }
      }
      return (text[0:end].to_owned(), pkg.field("Architecture").unwrap())
    }
  }
  raise RepoError::Invalid(
    file=file.name,
    message="the deb has no control file",
  )
}

///|
fn check_name(file : PackageFile, suffix : String) -> Unit raise RepoError {
  let name = file.name
  if !name.has_suffix(suffix) {
    raise RepoError::Invalid(
      file=name,
      message="the name must end with \{suffix}",
    )
  }
  for c in name {
    if c == '/' || c == '\\' || c == ' ' || c.to_int() < 32 {
      raise RepoError::Invalid(
        file=name,
        message="the name must be a plain file name without spaces or slashes",
      )
    }
  }
}

///|
fn sorted_by_name(files : Array[PackageFile]) -> Array[PackageFile] {
  let copy = files.copy()
  copy.sort_by((a, b) => {
    if a.name < b.name {
      -1
    } else if a.name > b.name {
      1
    } else {
      0
    }
  })
  copy
}

///|
fn check_unique(files : Array[PackageFile]) -> Unit raise RepoError {
  for i in 1..<files.length() {
    if files[i].name == files[i - 1].name {
      raise RepoError::Invalid(
        file=files[i].name,
        message="the file name is used twice",
      )
    }
  }
}

///|
fn pad_left(text : String, width : Int32) -> String {
  let mut result = text
  while result.length() < width {
    result = " " + result
  }
  result
}

///|
fn hash_section(
  title : String,
  entries : Array[(String, Bytes)],
  digest : (Bytes) -> String,
) -> String {
  let out = StringBuilder()
  out.write_string(title)
  out.write_string(":\n")
  for entry in entries {
    out.write_string(
      " \{digest(entry.1)} \{pad_left(entry.1.length().to_string(), 16)} \{entry.0}\n",
    )
  }
  out.to_string()
}

///|
/// The index files of a flat apt repository for the given debs: `Packages`,
/// `Packages.gz`, `Packages.xz` and `Release`.
///
/// The debs are expected next to the index files, which then lists them as
/// `Filename: ./<name>`. `date` (seconds since the epoch) goes into the
/// `Release` file; the result depends only on the inputs, so it is
/// reproducible. Use it with a source line such as
/// `deb [trusted=yes] file:/path/to/repo ./`; nothing is signed.
pub fn apt_index(
  debs : Array[PackageFile],
  date~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let files = sorted_by_name(debs)
  check_unique(files)
  let stanzas = StringBuilder()
  let architectures : Array[String] = []
  for file in files {
    check_name(file, ".deb")
    let (control, arch) = control_text(file)
    if !architectures.contains(arch) {
      architectures.push(arch)
    }
    stanzas.write_string(control)
    stanzas.write_string("\nFilename: ./\{file.name}\n")
    stanzas.write_string("Size: \{file.data.length()}\n")
    stanzas.write_string("MD5sum: \{md5_hex(file.data)}\n")
    stanzas.write_string("SHA1: \{sha1_hex(file.data)}\n")
    stanzas.write_string("SHA256: \{sha256_hex(file.data)}\n\n")
  }
  let packages = @utf8.encode(stanzas.to_string())
  let gz = @compress.compress(packages, Gzip) catch {
    err => raise RepoError::Invalid(file="Packages.gz", message="\{err}")
  }
  let xz = @compress.compress(packages, Xz) catch {
    err => raise RepoError::Invalid(file="Packages.xz", message="\{err}")
  }
  architectures.sort()
  let indexes : Array[(String, Bytes)] = [
    ("Packages", packages),
    ("Packages.gz", gz),
    ("Packages.xz", xz),
  ]
  let release = StringBuilder()
  release.write_string("Date: \{rfc2822(date)}\n")
  if architectures.length() > 0 {
    release.write_string("Architectures: \{architectures.join(" ")}\n")
  }
  release.write_string(hash_section("MD5Sum", indexes, md5_hex))
  release.write_string(hash_section("SHA1", indexes, sha1_hex))
  release.write_string(hash_section("SHA256", indexes, sha256_hex))
  [
    indexes[0],
    indexes[1],
    indexes[2],
    ("Release", @utf8.encode(release.to_string())),
  ]
}

///|
/// The newest modification time among the files of a deb (seconds since the
/// epoch), used as a reproducible default date for a repository.
pub fn deb_time(file : PackageFile) -> Int64 raise RepoError {
  let pkg = @deb.read(file.data) catch {
    err => raise RepoError::Invalid(file=file.name, message="\{err}")
  }
  let mut newest = 0L
  for entry in pkg.files {
    if entry.mtime > newest {
      newest = entry.mtime
    }
  }
  newest
}
