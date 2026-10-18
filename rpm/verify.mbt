///|
/// Hex digest of `data` for a `PGPHASHALGO_*` number, or `None` for
/// algorithms this package does not implement.
fn digest_hex(algorithm : Int32, data : Bytes) -> String? {
  match algorithm {
    1 => Some(@crypto.bytes_to_hex_string(@crypto.md5(data)))
    2 => Some(@crypto.bytes_to_hex_string(@crypto.sha1(data)))
    8 => Some(@crypto.bytes_to_hex_string(@crypto.sha256(data)))
    9 => Some(@crypto.bytes_to_hex_string(@crypto.sha384(data)))
    10 => Some(@crypto.bytes_to_hex_string(@crypto.sha512(data)))
    _ => None
  }
}

///|
fn has_dotdot(path : String) -> Bool {
  for segment in path.split("/") {
    if segment == ".." {
      return true
    }
  }
  false
}

///|
fn strip_dot_slash(path : String) -> String {
  if path.has_prefix(".") {
    path[1:].to_owned()
  } else {
    path
  }
}

///|
/// Check the integrity of an opened rpm and return one line per problem; an
/// empty array means it is sound.
///
/// Checked: the header digests of the signature header (SHA-256, SHA-1), the
/// size and MD5 of header plus payload, the payload digest, the mandatory
/// tags, and, once the payload is unpacked, its size, the file names, sizes,
/// link targets and the digest of every regular file.
///
/// Raises `Unsupported` when the package is otherwise sound but its payload
/// uses a compression this package cannot unpack (xz, zstd, ...), because
/// the file contents then remain unchecked.
pub fn RpmPackage::verify(self : RpmPackage) -> Array[String] raise RpmError {
  let problems : Array[String] = []
  let sig = self.signature
  match sig.string(273) {
    Some(expected) => {
      let actual = digest_hex(8, self.header_bytes).unwrap()
      if actual != expected {
        problems.push(
          "header SHA-256 mismatch (signature says \{expected}, header is \{actual})",
        )
      }
    }
    None => ()
  }
  match sig.string(269) {
    Some(expected) => {
      let actual = digest_hex(2, self.header_bytes).unwrap()
      if actual != expected {
        problems.push(
          "header SHA-1 mismatch (signature says \{expected}, header is \{actual})",
        )
      }
    }
    None => ()
  }
  let sizes = sig.numbers(270)
  let size_values = if sizes.length() > 0 { sizes } else { sig.numbers(1000) }
  if size_values.length() > 0 {
    let actual = (self.header_bytes.length() + self.payload.length()).to_int64()
    if size_values[0] != actual {
      problems.push(
        "size mismatch (signature says \{size_values[0]}, header plus payload are \{actual} bytes)",
      )
    }
  }
  match sig.get(1004) {
    Some(Bin(expected)) => {
      let both = Bytes::from_array([..self.header_bytes, ..self.payload])
      let actual = @crypto.md5(both)
      let actual_bytes = Bytes::from_array(actual[:])
      if actual_bytes != expected {
        problems.push("MD5 of header and payload does not match the signature")
      }
    }
    _ => ()
  }
  match self.header.strings(5092) {
    [expected, ..] => {
      let algorithm = match self.header.ints(5093) {
        [a, ..] => a
        [] => 8
      }
      match digest_hex(algorithm, self.payload) {
        Some(actual) =>
          if actual != expected {
            problems.push(
              "payload digest mismatch (header says \{expected}, payload is \{actual})",
            )
          }
        None =>
          raise RpmError::Unsupported(
            message="payload digest algorithm \{algorithm} is not supported",
          )
      }
    }
    [] => ()
  }
  for
    name in [
      (1000, "Name"),
      (1001, "Version"),
      (1002, "Release"),
      (1022, "Arch"),
    ] {
    if self.header.string(name.0) is None {
      problems.push("main header: missing required tag \{name.1}")
    }
  }
  let files = self.files()
  let seen : Map[String, Bool] = Map([])
  for file in files {
    if has_dotdot(file.path) {
      problems.push("\{file.path}: path escapes the installation root")
    }
    if seen.contains(file.path) {
      problems.push("\{file.path}: listed more than once in the header")
    }
    seen[file.path] = true
  }
  let raw = try self.raw_payload(1073741824) catch {
    err =>
      if problems.length() > 0 {
        // Damage already found is the more useful report.
        return problems
      } else {
        raise err
      }
  } noraise {
    bytes => bytes
  }
  match sig.numbers(271) {
    [expected, ..] =>
      if expected != raw.length().to_int64() {
        problems.push(
          "payload size mismatch (signature says \{expected}, payload unpacks to \{raw.length()} bytes)",
        )
      }
    [] =>
      match sig.numbers(1007) {
        [expected, ..] =>
          if expected != raw.length().to_int64() {
            problems.push(
              "payload size mismatch (signature says \{expected}, payload unpacks to \{raw.length()} bytes)",
            )
          }
        [] => ()
      }
  }
  let entries = @cpio.parse(raw) catch {
    err => raise RpmError::Corrupt(offset=-1, message="payload: \{err}")
  }
  if entries.length() != files.length() {
    problems.push(
      "the header lists \{files.length()} files but the payload holds \{entries.length()}",
    )
    return problems
  }
  let algorithm = match self.header.ints(5011) {
    [a, ..] => a
    [] => 1
  }
  for i, file in files {
    let entry = entries[i]
    if strip_dot_slash(entry.path) != file.path {
      problems.push(
        "\{file.path}: payload entry \{i} is named \"\{entry.path}\"",
      )
      continue
    }
    let kind = file.mode & 0o170000
    // Hard links keep their data in the last link only.
    if entry.nlink > 1 && entry.data.length() == 0 && kind == 0o100000 {
      continue
    }
    if kind == 0o100000 {
      if entry.data.length().to_int64() != file.size {
        problems.push(
          "\{file.path}: size \{entry.data.length()} in the payload, \{file.size} in the header",
        )
      } else if file.digest != "" {
        match digest_hex(algorithm, entry.data) {
          Some(actual) =>
            if actual != file.digest {
              problems.push(
                "\{file.path}: digest mismatch (header says \{file.digest}, content is \{actual})",
              )
            }
          None =>
            raise RpmError::Unsupported(
              message="file digest algorithm \{algorithm} is not supported",
            )
        }
      }
    } else if kind == 0o120000 {
      if @utf8.decode_lossy(entry.data) != file.link {
        problems.push(
          "\{file.path}: link target differs between payload and header",
        )
      }
    }
  }
  problems
}
