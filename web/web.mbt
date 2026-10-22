///|
/// The browser side of linuxpkg: functions that take and return text so that
/// JavaScript can call them without knowing MoonBit types. Files travel as
/// base64 strings, results are JSON texts, and nothing here ever throws: a
/// problem is reported as `{"error": "..."}`.
priv enum Package {
  Deb(@deb.DebPackage)
  Rpm(@rpm.RpmPackage)
  Arch(@arch.ArchPackage)
  Apk(@apk.ApkPackage)
}

///|
fn error_json(message : String) -> String {
  Json::object({ "error": Json::string(message) }).stringify()
}

///|
fn base64_of(data : Bytes) -> String {
  @base64.encode(data[:])
}

///|
fn starts_with(data : Bytes, prefix : Bytes) -> Bool {
  data.length() >= prefix.length() &&
  data[0:prefix.length()].to_owned() == prefix
}

///|
/// Tell the kind of package from its bytes (and, for the two that are gzip
/// compatible, from the file name), the way the command line does.
fn load(name : String, data : Bytes) -> Package raise {
  if starts_with(data, b"!<arch>\n") {
    return Deb(@deb.read(data))
  }
  if starts_with(data, b"\xed\xab\xee\xdb") {
    return Rpm(@rpm.read(data))
  }
  if starts_with(data, b"\x1f\x8b") {
    if name.has_suffix(".apk") {
      return Apk(@apk.read(data))
    }
    try @apk.read(data) catch {
      _ => ()
    } noraise {
      apk => return Apk(apk)
    }
  }
  Arch(@arch.read(data))
}

///|
fn Package::report(self : Package) -> Json raise {
  match self {
    Deb(p) => p.to_json()
    Rpm(p) => p.to_json()
    Arch(p) => p.to_json()
    Apk(p) => p.to_json()
  }
}

///|
fn Package::problems(self : Package) -> Array[String] raise {
  match self {
    Deb(p) => p.verify()
    Rpm(p) => p.verify()
    Arch(p) => p.verify()
    Apk(p) => p.verify()
  }
}

///|
fn Package::checked(self : Package) -> Int32 {
  match self {
    Deb(p) => p.md5sums.length()
    Arch(p) => p.checked_files()
    Apk(p) => p.checked_files()
    Rpm(p) => p.header.strings(1035).filter(d => d != "").length()
  }
}

///|
fn Package::kind(self : Package) -> String {
  match self {
    Deb(_) => "deb"
    Rpm(_) => "rpm"
    Arch(_) => "arch"
    Apk(_) => "apk"
  }
}

///|
/// What the package says about its signature (rpm and Alpine carry it inside,
/// Arch packages have a separate `.sig`, deb packages are signed through the
/// repository). With `keyring` it is checked.
fn Package::signature(self : Package, keyring : @sign.PublicKeyring?) -> Json {
  let status = match self {
    Rpm(p) => Some(p.signature_status(keyring))
    Apk(p) => Some(p.signature_status(keyring))
    _ => None
  }
  match status {
    None => Json::object({ "state": Json::string("not applicable") })
    Some(Unsigned) => Json::object({ "state": Json::string("unsigned") })
    Some(Signed(key_id~)) =>
      Json::object({
        "state": Json::string("signed"),
        "key": Json::string(key_id),
      })
    Some(Good(verified)) =>
      Json::object({
        "state": Json::string("good"),
        "key": Json::string(verified.fingerprint),
      })
    Some(Bad(message)) =>
      Json::object({
        "state": Json::string("bad"),
        "message": Json::string(message),
      })
  }
}

///|
fn keyring_of(text : String) -> @sign.PublicKeyring? raise {
  if text.trim().to_owned() == "" {
    None
  } else {
    Some(@sign.PublicKeyring::from_armored(text))
  }
}

///|
/// Metadata and file list of a package: the same JSON as `linuxpkg inspect
/// --json`, under `report`, with the integrity `problems`, the number of
/// `checked` checksums and the `signature` state. `name` is the file name (it
/// tells an Alpine package from an Arch one), `data` the file in base64.
pub fn lp_inspect(name : String, data : String) -> String {
  try {
    let pkg = load(name, @base64.decode(data))
    Json::object({
      "kind": Json::string(pkg.kind()),
      "report": pkg.report(),
      "problems": Json::array(pkg.problems().map(Json::string)),
      "checked": Json::number(pkg.checked().to_double()),
      "signature": pkg.signature(None),
    }).stringify()
  } catch {
    err => error_json("\{err}")
  }
}

///|
/// Check the checksums of a package, and its signature against `keyring`
/// (armored OpenPGP keys or an Alpine `.rsa.pub`; empty text for none).
pub fn lp_verify(name : String, data : String, keyring : String) -> String {
  try {
    let pkg = load(name, @base64.decode(data))
    let ring = keyring_of(keyring)
    Json::object({
      "kind": Json::string(pkg.kind()),
      "problems": Json::array(pkg.problems().map(Json::string)),
      "checked": Json::number(pkg.checked().to_double()),
      "signature": pkg.signature(ring),
    }).stringify()
  } catch {
    err => error_json("\{err}")
  }
}

///|
fn files_of(text : String) -> Map[String, Bytes] raise {
  let files : Map[String, Bytes] = Map([])
  match @json.parse(text) {
    Object(map) =>
      for key, value in map {
        match value {
          String(b64) => files[key] = @base64.decode(b64)
          _ => fail("file \"\{key}\" must be given as a base64 string")
        }
      }
    _ => fail("files must be an object of base64 strings")
  }
  files
}

///|
/// Build the packages of a `linuxpkg.json` text. `files` is a JSON object that
/// maps each `src` path of the configuration to its content in base64;
/// `formats` is `deb`, `rpm`, `arch`, `apk` or `all`, `compression` is `""`
/// (the configuration decides) or `none`, `gzip`, `xz`, `zstd`; `mtime` is the
/// build time in seconds (used when the configuration has none). The result
/// lists `{name, format, data}` with the content in base64, or `{error}`. The
/// bytes are the ones the command line writes for the same input.
pub fn lp_build(
  config : String,
  files : String,
  formats : String,
  compression : String,
  mtime : Double,
) -> String {
  try {
    let parsed = @spec.Config::parse(config)
    let spec = parsed.resolve(files_of(files), default_mtime=mtime.to_int64())
    let forced : @compress.Compression? = if compression == "" {
      None
    } else {
      match @compress.Compression::parse(compression) {
        Some(c) => Some(c)
        None => fail("unknown compression \"\{compression}\"")
      }
    }
    let out : Array[Json] = []
    let skipped : Array[Json] = []
    let add = (name : String, format : String, data : Bytes) => {
      out.push(
        Json::object({
          "name": Json::string(name),
          "format": Json::string(format),
          "data": Json::string(base64_of(data)),
        }),
      )
    }
    let want = (f : String) => formats == f || formats == "all"
    if want("deb") {
      let c = forced.unwrap_or(parsed.deb_compression())
      add(@deb.file_name(spec), "deb", @deb.build(spec, compression=c))
    }
    if want("rpm") {
      let c = forced.unwrap_or(parsed.rpm_compression())
      add(@rpm.file_name(spec), "rpm", @rpm.build(spec, compression=c))
    }
    if want("arch") {
      let c = forced.unwrap_or(parsed.arch_compression())
      add(
        @arch.file_name(spec, compression=c),
        "arch",
        @arch.build(spec, compression=c),
      ) catch {
        err =>
          if formats == "arch" {
            raise err
          } else {
            skipped.push(Json::string("arch: \{err}"))
          }
      }
    }
    if want("apk") {
      add(@apk.file_name(spec), "apk", @apk.build(spec)) catch {
        err =>
          if formats == "apk" {
            raise err
          } else {
            skipped.push(Json::string("apk: \{err}"))
          }
      }
    }
    Json::object({
      "packages": Json::array(out),
      "skipped": Json::array(skipped),
    }).stringify()
  } catch {
    err => error_json("\{err}")
  }
}
