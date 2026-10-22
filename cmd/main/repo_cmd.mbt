///|
/// Files of `dir` whose name satisfies `wanted`, as `PackageFile`s sorted by
/// name. Only the directory itself is looked at, not its subdirectories.
fn package_files_where(
  dir : String,
  wanted : (String) -> Bool,
) -> Array[@repo.PackageFile] raise CliError {
  let names = @fs.read_dir(dir) catch {
    err => raise Failed(describe_io(err, "cannot list \"\{dir}\""))
  }
  let found : Array[String] = []
  for name in names {
    if wanted(name) {
      found.push(name)
    }
  }
  found.sort()
  found.map(name => { name, data: read_bytes(join_path(dir, name)), })
}

///|
/// Files of `dir` whose name ends with `suffix`.
fn package_files(
  dir : String,
  suffix : String,
) -> Array[@repo.PackageFile] raise CliError {
  package_files_where(dir, name => name.has_suffix(suffix))
}

///|
fn is_arch_package(name : String) -> Bool {
  name.contains(".pkg.tar") && !name.has_suffix(".sig")
}

///|
/// Remove metadata of an earlier run so that stale checksummed files do not
/// pile up in `repodata/`.
fn remove_old_repodata(dir : String) -> Unit raise CliError {
  if !@fs.path_exists(dir) {
    return
  }
  let names = @fs.read_dir(dir) catch {
    err => raise Failed(describe_io(err, "cannot list \"\{dir}\""))
  }
  for name in names {
    let ours = name == "repomd.xml" ||
      name.has_suffix("-primary.xml.gz") ||
      name.has_suffix("-filelists.xml.gz") ||
      name.has_suffix("-other.xml.gz")
    if ours {
      @fs.remove_file(join_path(dir, name)) catch {
        err => raise Failed(describe_io(err, "cannot remove \"\{name}\""))
      }
    }
  }
}

///|
fn write_index(
  dir : String,
  files : Array[(String, Bytes)],
) -> Unit raise CliError {
  for file in files {
    let target = join_path(dir, file.0)
    ensure_dir(dirname(target))
    write_bytes(target, file.1)
    println("wrote \{target} (\{file.1.length()} bytes)")
  }
}

///|
/// The date of the metadata when `SOURCE_DATE_EPOCH` is not set: the newest
/// build time found in the packages, so running the command twice gives the
/// same files.
fn newest_time(
  debs : Array[@repo.PackageFile],
  rpms : Array[@repo.PackageFile],
  archs : Array[@repo.PackageFile],
  apks : Array[@repo.PackageFile],
) -> Int64 raise CliError {
  let mut newest = 0L
  let times : Array[Int64] = []
  for deb in debs {
    times.push(@repo.deb_time(deb) catch { err => raise Failed("\{err}") })
  }
  for rpm in rpms {
    times.push(@repo.rpm_time(rpm) catch { err => raise Failed("\{err}") })
  }
  for pkg in archs {
    times.push(@repo.arch_time(pkg) catch { err => raise Failed("\{err}") })
  }
  for pkg in apks {
    times.push(@repo.apk_time(pkg) catch { err => raise Failed("\{err}") })
  }
  for t in times {
    if t > newest {
      newest = t
    }
  }
  newest
}

///|
fn cmd_repo(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    {
      "--format": "format",
      "-f": "format",
      "--sign-key": "sign_key",
      "--name": "name",
      "-n": "name",
      "--apk-key-name": "apk_key_name",
    },
    Map([]),
  )
  let dir = match options.positional {
    [path] => path
    [] => raise Usage("repo needs the directory that holds the packages")
    _ => raise Usage("repo takes exactly one directory")
  }
  let format = match options.value("format") {
    Some(f) => f
    None => "all"
  }
  if format != "deb" &&
    format != "rpm" &&
    format != "arch" &&
    format != "apk" &&
    format != "all" {
    raise Usage(
      "unknown format \"\{format}\", expected deb, rpm, arch, apk or all",
    )
  }
  if !@fs.path_exists(dir) {
    raise Failed("\"\{dir}\" does not exist")
  }
  let signer = match options.value("sign_key") {
    Some(path) => Some((load_signing_key(path), load_keyring(path)))
    None => None
  }
  let wants = (kind : String) => format == kind || format == "all"
  let debs = if wants("deb") { package_files(dir, ".deb") } else { [] }
  let rpms = if wants("rpm") { package_files(dir, ".rpm") } else { [] }
  let archs = if wants("arch") {
    package_files_where(dir, is_arch_package)
  } else {
    []
  }
  let apks = if wants("apk") { package_files(dir, ".apk") } else { [] }
  if debs.length() == 0 &&
    rpms.length() == 0 &&
    archs.length() == 0 &&
    apks.length() == 0 {
    raise Failed("no \{format} packages found in \"\{dir}\"")
  }
  let stamp = match source_date_epoch() {
    Some(t) => t
    None => newest_time(debs, rpms, archs, apks)
  }
  if debs.length() > 0 {
    let files = @repo.apt_index(debs, date=stamp) catch {
      err => raise Failed("\{err}")
    }
    write_index(dir, files)
    let problems = @repo.check_apt(files, debs)
    if problems.length() > 0 {
      raise Failed("the apt index is inconsistent: \{problems.join("; ")}")
    }
    match signer {
      None =>
        println(
          "apt: \{debs.length()} package(s); use `deb [trusted=yes] file:<dir> ./`",
        )
      Some((key, ring)) => {
        let signed = @repo.sign_apt(files, key, created=stamp) catch {
          err => raise Failed("\{err}")
        }
        write_index(dir, signed)
        let bad = @repo.check_apt_signature(files + signed, ring)
        if bad.length() > 0 {
          raise Failed("the apt signatures do not verify: \{bad.join("; ")}")
        }
        println(
          "apt: \{debs.length()} package(s) signed by \{key.fingerprint()}; use `deb [signed-by=<public key file>] file:<dir> ./`",
        )
      }
    }
  }
  if rpms.length() > 0 {
    let files = @repo.yum_index(rpms, timestamp=stamp) catch {
      err => raise Failed("\{err}")
    }
    let repodata = join_path(dir, "repodata")
    ensure_dir(repodata)
    remove_old_repodata(repodata)
    write_index(dir, files)
    let problems = @repo.check_yum(files, rpms)
    if problems.length() > 0 {
      raise Failed("the yum index is inconsistent: \{problems.join("; ")}")
    }
    match signer {
      None =>
        println(
          "yum: \{rpms.length()} package(s); use a .repo file with baseurl=file://<dir> and gpgcheck=0",
        )
      Some((key, ring)) => {
        let signed = @repo.sign_yum(files, key, created=stamp) catch {
          err => raise Failed("\{err}")
        }
        write_index(dir, signed)
        let bad = @repo.check_yum_signature(files + signed, ring)
        if bad.length() > 0 {
          raise Failed("the yum signature does not verify: \{bad.join("; ")}")
        }
        println(
          "yum: \{rpms.length()} package(s) signed by \{key.fingerprint()}; use a .repo file with repo_gpgcheck=1 and gpgkey=<public key file>",
        )
      }
    }
  }
  if archs.length() > 0 {
    let name = match options.value("name") {
      Some(name) => name
      None => "linuxpkg"
    }
    let signatures = package_files(dir, ".sig")
    let files = @repo.arch_index(archs, signatures, name~, date=stamp) catch {
      err => raise Failed("\{err}")
    }
    write_index(dir, files)
    let problems = @repo.check_arch(files, archs, signatures, name~)
    if problems.length() > 0 {
      raise Failed(
        "the pacman database is inconsistent: \{problems.join("; ")}",
      )
    }
    match signer {
      None =>
        println(
          "arch: \{archs.length()} package(s); use [\{name}] with Server = file://<dir> and SigLevel = Optional TrustAll",
        )
      Some((key, ring)) => {
        let signed = @repo.sign_arch(files, key, created=stamp) catch {
          err => raise Failed("\{err}")
        }
        write_index(dir, signed)
        let bad = @repo.check_arch_signature(files + signed, ring, name~)
        if bad.length() > 0 {
          raise Failed("the pacman signatures do not verify: \{bad.join("; ")}")
        }
        println(
          "arch: \{archs.length()} package(s) signed by \{key.fingerprint()}; use [\{name}] with Server = file://<dir> and SigLevel = Required DatabaseRequired",
        )
      }
    }
  }
  if apks.length() > 0 {
    let description = match options.value("name") {
      Some(name) => name
      None => "linuxpkg"
    }
    let files = @repo.apk_index(apks, description~, date=stamp) catch {
      err => raise Failed("\{err}")
    }
    let problems = @repo.check_apk(files, apks)
    if problems.length() > 0 {
      raise Failed("the apk index is inconsistent: \{problems.join("; ")}")
    }
    match signer {
      None => {
        write_index(dir, files)
        println(
          "apk: \{apks.length()} package(s); use `apk --repository <dir> --allow-untrusted add ...`",
        )
      }
      Some((key, _)) if !key.is_rsa() =>
        if format == "apk" {
          raise Failed("Alpine repositories can only be signed with an RSA key")
        } else {
          eprintln(
            "linuxpkg: the apk repository is not written: Alpine only supports RSA keys",
          )
        }
      Some((key, ring)) => {
        let key_name = apk_key_name(key, options.value("apk_key_name"))
        let signed = @repo.sign_apk(files, key, key_name~, created=stamp) catch {
          err => raise Failed("\{err}")
        }
        let written = files.map(f => {
          match signed.filter(s => s.0 == f.0) {
            [s] => s
            _ => f
          }
        })
        write_index(dir, written)
        let bad = @repo.check_apk_signature(written, ring)
        if bad.length() > 0 {
          raise Failed("the apk signatures do not verify: \{bad.join("; ")}")
        }
        println(
          "apk: \{apks.length()} package(s) signed by \{key.fingerprint()}; put the output of `linuxpkg key apk-pub` as \{key_name} in /etc/apk/keys/ and use `apk --repository <dir> add ...`",
        )
      }
    }
  }
  0
}
