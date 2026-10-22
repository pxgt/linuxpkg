///|
/// Print what the package says about its signature, and check it when a
/// keyring is given. Returns the problems found.
fn check_signature(
  pkg : Package,
  path : String,
  keyring : @sign.PublicKeyring?,
) -> Array[String] raise CliError {
  match pkg {
    Rpm(rpm) =>
      match rpm.signature_status(keyring) {
        Unsigned =>
          if keyring is Some(_) {
            return ["not signed"]
          } else {
            println("\{path}: signature: none")
          }
        Signed(key_id~) =>
          println(
            "\{path}: signature: signed by key \{key_id} (not checked, no --keyring)",
          )
        Good(verified) =>
          println("\{path}: signature: OK (key \{verified.fingerprint})")
        Bad(message) => return [message]
      }
    Arch(_) => {
      let sig_path = path + ".sig"
      if !@fs.path_exists(sig_path) {
        if keyring is Some(_) {
          return ["not signed (\{sig_path} is missing)"]
        }
        println("\{path}: signature: none")
      } else {
        let signature = read_bytes(sig_path)
        match keyring {
          None =>
            try {
              let info = @sign.signature_info(signature)
              println(
                "\{path}: signature: signed by key \{info.key_id} (not checked, no --keyring)",
              )
            } catch {
              err => return ["\{sig_path}: \{err}"]
            }
          Some(ring) =>
            try {
              let verified = ring.verify_detached(
                read_bytes(path)[:],
                signature,
              )
              println("\{path}: signature: OK (key \{verified.fingerprint})")
            } catch {
              err => return ["\{err}"]
            }
        }
      }
    }
    Apk(apk) =>
      match apk.signature_status(keyring) {
        Unsigned =>
          if keyring is Some(_) {
            return ["not signed"]
          } else {
            println("\{path}: signature: none")
          }
        Signed(key_id~) =>
          println(
            "\{path}: signature: signed by key \{key_id} (not checked, no --keyring)",
          )
        Good(verified) =>
          println(
            "\{path}: signature: OK (key \{verified.key_id}, \{verified.fingerprint})",
          )
        Bad(message) => return [message]
      }
    Deb(_) =>
      if keyring is Some(_) {
        raise Failed(
          "\{path}: this kind of package is not signed by itself; check the signature of the repository (`verify <directory> --keyring KEY`)",
        )
      }
  }
  []
}

///|
fn read_optional(path : String) -> Bytes? raise CliError {
  if @fs.path_exists(path) {
    Some(read_bytes(path))
  } else {
    None
  }
}

///|
/// An `APKINDEX.tar.gz` with a signature stream in front of the index.
fn is_signed_index(data : Bytes) -> Bool {
  try @compress.gzip_members(data[:], max_size=1 << 28).length() == 2 catch {
    _ => false
  }
}

///|
/// Check the signatures of an apt flat repository and a dnf repository in
/// `dir`. Without a keyring only report which signature files are there.
fn verify_repository(
  dir : String,
  keyring : @sign.PublicKeyring?,
) -> Int32 raise CliError {
  let apt : Array[(String, Bytes)] = []
  for name in ["Release", "Release.gpg", "InRelease"] {
    if read_optional(join_path(dir, name)) is Some(data) {
      apt.push((name, data))
    }
  }
  let yum : Array[(String, Bytes)] = []
  for name in ["repodata/repomd.xml", "repodata/repomd.xml.asc"] {
    if read_optional(join_path(dir, name)) is Some(data) {
      yum.push((name, data))
    }
  }
  // Alpine: one directory per architecture with an APKINDEX.tar.gz.
  let apk : Array[(String, Bytes)] = []
  // pacman: <name>.db.tar.gz and friends, with the .sig files next to them.
  let pacman : Array[(String, Bytes)] = []
  let pacman_names : Array[String] = []
  let listing = @fs.read_dir(dir) catch {
    err => raise Failed(describe_io(err, "cannot list \"\{dir}\""))
  }
  for name in listing {
    let sub_index = join_path(join_path(dir, name), "APKINDEX.tar.gz")
    if read_optional(sub_index) is Some(data) {
      apk.push(("\{name}/APKINDEX.tar.gz", data))
    }
    if name.has_suffix(".db.tar.gz") {
      pacman_names.push(name[0:name.length() - 10].to_owned())
    }
  }
  for repo_name in pacman_names {
    for
      suffix in [
        ".db", ".db.tar.gz", ".files", ".files.tar.gz", ".db.sig", ".db.tar.gz.sig",
        ".files.sig", ".files.tar.gz.sig",
      ] {
      if read_optional(join_path(dir, repo_name + suffix)) is Some(data) {
        pacman.push((repo_name + suffix, data))
      }
    }
  }
  if apt.length() == 0 &&
    yum.length() == 0 &&
    apk.length() == 0 &&
    pacman.length() == 0 {
    raise Failed(
      "\"\{dir}\" has no apt, dnf, pacman or apk repository metadata",
    )
  }
  let problems : Array[String] = []
  if apt.length() > 0 {
    match keyring {
      Some(ring) => {
        let found = @repo.check_apt_signature(apt, ring)
        if found.length() == 0 {
          println("\{dir}: apt: Release.gpg and InRelease OK")
        }
        for problem in found {
          problems.push("apt: \{problem}")
        }
      }
      None => {
        let signed = apt.filter(f => f.0 != "Release").map(f => f.0)
        if signed.length() == 0 {
          println("\{dir}: apt: unsigned")
        } else {
          println(
            "\{dir}: apt: signed (\{signed.join(", ")}), not checked, no --keyring",
          )
        }
      }
    }
  }
  if yum.length() > 0 {
    match keyring {
      Some(ring) => {
        let found = @repo.check_yum_signature(yum, ring)
        if found.length() == 0 {
          println("\{dir}: dnf: repomd.xml.asc OK")
        }
        for problem in found {
          problems.push("dnf: \{problem}")
        }
      }
      None =>
        if yum.length() > 1 {
          println(
            "\{dir}: dnf: signed (repomd.xml.asc), not checked, no --keyring",
          )
        } else {
          println("\{dir}: dnf: unsigned")
        }
    }
  }
  if apk.length() > 0 {
    match keyring {
      Some(ring) => {
        let found = @repo.check_apk_signature(apk, ring)
        if found.length() == 0 {
          println(
            "\{dir}: apk: APKINDEX.tar.gz of \{apk.length()} architecture(s) OK",
          )
        }
        for problem in found {
          problems.push("apk: \{problem}")
        }
      }
      None => {
        let signed = apk.filter(f => is_signed_index(f.1))
        println(
          "\{dir}: apk: \{signed.length()} of \{apk.length()} index(es) signed, not checked, no --keyring",
        )
      }
    }
  }
  for repo_name in pacman_names {
    match keyring {
      Some(ring) => {
        let found = @repo.check_arch_signature(pacman, ring, name=repo_name)
        if found.length() == 0 {
          println("\{dir}: pacman: \{repo_name}.db and .files OK")
        }
        for problem in found {
          problems.push("pacman: \{problem}")
        }
      }
      None => {
        let signed = pacman.filter(f => f.0 == repo_name + ".db.sig")
        println(
          if signed.length() > 0 {
            "\{dir}: pacman: \{repo_name}.db signed, not checked, no --keyring"
          } else {
            "\{dir}: pacman: \{repo_name}.db unsigned"
          },
        )
      }
    }
  }
  if problems.length() > 0 {
    for problem in problems {
      eprintln("\{dir}: \{problem}")
    }
    raise Mismatch(
      "\{dir}: signature check failed (\{problems.length()} problem(s))",
    )
  }
  0
}

///|
fn cmd_verify(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(args, { "--keyring": "keyring" }, Map([]))
  let path = match options.positional {
    [path] => path
    [] => raise Usage("verify needs the path of a package file")
    _ => raise Usage("verify takes exactly one package file")
  }
  let keyring = match options.value("keyring") {
    Some(file) => Some(load_keyring(file))
    None => None
  }
  let is_directory = @fs.is_dir(path) catch { _ => false }
  if is_directory {
    return verify_repository(path, keyring)
  }
  let pkg = load_package(path)
  let problems = pkg.problems(path)
  problems.append(check_signature(pkg, path, keyring))
  if problems.length() > 0 {
    for problem in problems {
      eprintln("\{path}: \{problem}")
    }
    raise Mismatch(
      "\{path}: verification failed (\{problems.length()} problem(s))",
    )
  }
  println("\{path}: OK (\{pkg.checked_files()} checksums verified)")
  0
}
