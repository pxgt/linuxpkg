///|
/// `Q1` and the base64 of the SHA-1 of the control stream: the id apk uses
/// for a package in an index.
fn apk_checksum(pkg : @apk.ApkPackage) -> String {
  "Q1" +
  @base64.encode(Bytes::from_iter(@crypto.sha1(pkg.control_packed).iter())[:])
}

///|
fn line(out : StringBuilder, key : String, value : String?) -> Unit {
  match value {
    Some(text) if text != "" => out.write_string("\{key}:\{text}\n")
    _ => ()
  }
}

///|
/// One `APKINDEX` paragraph, with the fields and in the order that
/// `apk index` writes them.
fn apk_stanza(
  file : PackageFile,
  pkg : @apk.ApkPackage,
) -> String raise RepoError {
  guard pkg.field("pkgname") is Some(name) &&
    pkg.field("pkgver") is Some(version) &&
    pkg.field("arch") is Some(_) else {
    raise Invalid(
      file=file.name,
      message=".PKGINFO lacks pkgname, pkgver or arch",
    )
  }
  let out = StringBuilder()
  out.write_string("C:\{apk_checksum(pkg)}\n")
  out.write_string("P:\{name}\n")
  out.write_string("V:\{version}\n")
  line(out, "A", pkg.field("arch"))
  out.write_string("S:\{file.data.length()}\n")
  line(out, "I", pkg.field("size"))
  line(out, "T", pkg.field("pkgdesc"))
  line(out, "U", pkg.field("url"))
  line(out, "L", pkg.field("license"))
  line(out, "o", pkg.field("origin"))
  line(out, "m", pkg.field("maintainer"))
  line(out, "t", pkg.field("builddate"))
  line(out, "c", pkg.field("commit"))
  line(out, "k", pkg.field("provider_priority"))
  line(out, "D", Some(pkg.fields("depend").join(" ")))
  line(out, "p", Some(pkg.fields("provides").join(" ")))
  line(out, "i", Some(pkg.fields("install_if").join(" ")))
  out.write_char('\n')
  out.to_string()
}

///|
fn apk_read(file : PackageFile) -> @apk.ApkPackage raise RepoError {
  check_name(file, ".apk")
  @apk.read(file.data) catch {
    err => raise Invalid(file=file.name, message="\{err}")
  }
}

///|
/// The directories an Alpine repository needs: one per architecture,
/// each with the packages of that architecture and the `noarch` ones. With
/// only `noarch` packages the directories of the two common architectures,
/// `x86_64` and `aarch64`, are made.
fn apk_groups(
  files : Array[(PackageFile, @apk.ApkPackage)],
) -> Array[(String, Array[(PackageFile, @apk.ApkPackage)])] {
  let archs : Array[String] = []
  for item in files {
    let arch = item.1.field("arch").unwrap_or("noarch")
    if arch != "noarch" && !archs.contains(arch) {
      archs.push(arch)
    }
  }
  if archs.is_empty() && files.length() > 0 {
    archs.push("aarch64")
    archs.push("x86_64")
  }
  archs.sort_by((a, b) => text_compare(a, b))
  archs.map(arch => {
    let members = files.filter(item => {
      let own = item.1.field("arch").unwrap_or("noarch")
      own == arch || own == "noarch"
    })
    (arch, members)
  })
}

///|
/// The files of an Alpine repository (`apk --repository <dir>`) for the
/// given `.apk` packages: for every architecture a directory `<arch>/` with
/// `APKINDEX.tar.gz` (a gzip tar with `DESCRIPTION` and `APKINDEX`, as `apk
/// index` writes it) and the packages themselves, since apk looks for them
/// next to the index. `date` is the time of the files in the archive, so the
/// output is reproducible. The index is not signed; see `sign_apk`.
pub fn apk_index(
  packages : Array[PackageFile],
  description~ : String,
  date~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let sorted = sorted_by_name(packages)
  check_unique(sorted)
  let opened = sorted.map(file => (file, apk_read(file)))
  let result : Array[(String, Bytes)] = []
  for group in apk_groups(opened) {
    let (arch, members) = group
    let text = StringBuilder()
    for pair in members {
      text.write_string(apk_stanza(pair.0, pair.1))
    }
    let entries : Array[@tar.Entry] = []
    if description != "" {
      entries.push(
        @tar.Entry::file("DESCRIPTION", @utf8.encode(description), mtime=date),
      )
    }
    entries.push(
      @tar.Entry::file("APKINDEX", @utf8.encode(text.to_string()), mtime=date),
    )
    let tar = @tar.build(entries) catch {
      err => raise Invalid(file="\{arch}/APKINDEX.tar.gz", message="\{err}")
    }
    let gz = @compress.compress(tar, Gzip) catch {
      err => raise Invalid(file="\{arch}/APKINDEX.tar.gz", message="\{err}")
    }
    result.push(("\{arch}/APKINDEX.tar.gz", gz))
    for pair in members {
      result.push(("\{arch}/\{pair.0.name}", pair.0.data))
    }
  }
  // apk fetches a package from the directory named after the architecture in
  // its own index entry, which is `noarch/` for architecture independent ones.
  for item in opened {
    if item.1.field("arch").unwrap_or("noarch") == "noarch" {
      result.push(("noarch/\{item.0.name}", item.0.data))
    }
  }
  result
}

///|
/// Sign every `APKINDEX.tar.gz` of `files` (the output of `apk_index`) like
/// `abuild-sign` does and return the signed indexes under the same names.
/// `key_name` is the file name of the public key in `/etc/apk/keys/`.
pub fn sign_apk(
  files : Array[(String, Bytes)],
  key : @sign.SigningKey,
  key_name~ : String,
  created~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let result : Array[(String, Bytes)] = []
  for file in files {
    if file.0.has_suffix("/APKINDEX.tar.gz") {
      let signed = @apk.sign_index(file.1[:], key, key_name~, created~) catch {
        err => raise Invalid(file=file.0, message="\{err}")
      }
      result.push((file.0, signed))
    }
  }
  result
}

///|
/// The signature names and the `APKINDEX` text of an `APKINDEX.tar.gz`, signed
/// or not.
fn apk_index_text(
  name : String,
  index : Bytes,
) -> (Array[String], String) raise RepoError {
  let members = @compress.gzip_members(index[:], max_size=1 << 28) catch {
    err => raise Invalid(file=name, message="\{err}")
  }
  if members.length() == 0 || members.length() > 2 {
    raise Invalid(file=name, message="expected one or two gzip streams")
  }
  let signatures : Array[String] = []
  if members.length() == 2 {
    let parsed = @tar.parse(members[0].1) catch {
      err => raise Invalid(file=name, message="signature: \{err}")
    }
    for entry in parsed {
      signatures.push(entry.path)
    }
  }
  let entries = @tar.parse(members[members.length() - 1].1) catch {
    err => raise Invalid(file=name, message="\{err}")
  }
  for entry in entries {
    if entry.path == "APKINDEX" && entry.kind is File(content) {
      return (signatures, @utf8.decode_lossy(content[:]))
    }
  }
  raise Invalid(file=name, message="has no APKINDEX file")
}

///|
/// Check the indexes of an Alpine repository (as made by `apk_index`, signed
/// or not) against the packages: every package is listed in the index of each
/// architecture directory it belongs to, with the right checksum, size and
/// version, and sits next to the index. Returns the problems found.
pub fn check_apk(
  files : Array[(String, Bytes)],
  packages : Array[PackageFile],
) -> Array[String] {
  let problems : Array[String] = []
  let opened : Array[(PackageFile, @apk.ApkPackage)] = []
  for file in packages {
    opened.push((file, apk_read(file))) catch {
      err => problems.push("\{err}")
    }
  }
  for group in apk_groups(opened) {
    let (arch, members) = group
    let index_name = "\{arch}/APKINDEX.tar.gz"
    match find_file(files, index_name) {
      None => problems.push("\{index_name}: missing")
      Some(index) =>
        try {
          let (_, text) = apk_index_text(index_name, index)
          let listed = text
            .split("\n\n")
            .map(p => p.to_owned())
            .filter(p => p != "")
            .collect()
          if listed.length() != members.length() {
            problems.push(
              "\{index_name}: lists \{listed.length()} packages, expected \{members.length()}",
            )
          }
          for pair in members {
            let stanza = apk_stanza(pair.0, pair.1)
              .trim_end(chars="\n")
              .to_owned()
            if !listed.contains(stanza) {
              problems.push(
                "\{index_name}: the entry of \{pair.0.name} is missing or wrong",
              )
            }
            let home = if pair.1.field("arch").unwrap_or("noarch") == "noarch" {
              ["\{arch}/\{pair.0.name}", "noarch/\{pair.0.name}"]
            } else {
              ["\{arch}/\{pair.0.name}"]
            }
            for path in home {
              match find_file(files, path) {
                Some(data) if data == pair.0.data => ()
                _ =>
                  problems.push(
                    "\{path}: missing or different from the package",
                  )
              }
            }
          }
        } catch {
          err => problems.push("\{err}")
        }
    }
  }
  problems
}

///|
/// Check the signatures of an Alpine repository: every `APKINDEX.tar.gz` in
/// `files` must be signed (`.SIGN.RSA.` or `.SIGN.RSA256.` in front of the
/// index) by a key of `ring` (a `.rsa.pub` PEM file or an OpenPGP RSA key).
/// Returns the problems found.
pub fn check_apk_signature(
  files : Array[(String, Bytes)],
  ring : @sign.PublicKeyring,
) -> Array[String] {
  let problems : Array[String] = []
  let mut seen = false
  for file in files {
    if !file.0.has_suffix("/APKINDEX.tar.gz") {
      continue
    }
    seen = true
    try {
      let members = @compress.gzip_members(file.1[:], max_size=1 << 28)
      if members.length() != 2 {
        problems.push("\{file.0}: not signed")
        continue
      }
      let rest = file.1[members[0].0.length():]
      let mut good = false
      let mut last = "no RSA signature"
      for entry in @tar.parse(members[0].1) {
        let content = match entry.kind {
          File(content) => content
          _ => continue
        }
        let parsed = if entry.path.has_prefix(".SIGN.RSA256.") {
          Some(@sign.RsaHash::Sha256)
        } else if entry.path.has_prefix(".SIGN.RSA.") {
          Some(@sign.RsaHash::Sha1)
        } else {
          None
        }
        match parsed {
          None => last = "\{entry.path}: only RSA signatures are supported"
          Some(hash) =>
            try {
              ignore(ring.verify_rsa(hash, rest, content[:]))
              good = true
            } catch {
              err => last = "\{entry.path}: \{err}"
            }
        }
      }
      if !good {
        problems.push("\{file.0}: \{last}")
      }
    } catch {
      err => problems.push("\{file.0}: \{err}")
    }
  }
  if !seen {
    problems.push("no APKINDEX.tar.gz")
  }
  problems
}

///|
/// The build time recorded in an Alpine package (seconds since the epoch),
/// used as a reproducible default date for a repository.
pub fn apk_time(file : PackageFile) -> Int64 raise RepoError {
  let pkg = apk_read(file)
  match pkg.field("builddate") {
    Some(text) => @string.parse_int64(text[:]) catch { _ => 0L }
    None => 0L
  }
}
