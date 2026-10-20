///|
/// Files of `dir` whose name ends with `suffix`, as `PackageFile`s sorted by
/// name. Only the directory itself is looked at, not its subdirectories.
fn package_files(
  dir : String,
  suffix : String,
) -> Array[@repo.PackageFile] raise CliError {
  let names = @fs.read_dir(dir) catch {
    err => raise Failed(describe_io(err, "cannot list \"\{dir}\""))
  }
  let found : Array[String] = []
  for name in names {
    if name.has_suffix(suffix) {
      found.push(name)
    }
  }
  found.sort()
  found.map(name => { name, data: read_bytes(join_path(dir, name)), })
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
    write_bytes(target, file.1)
    println("wrote \{target} (\{file.1.length()} bytes)")
  }
}

///|
fn cmd_repo(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    { "--format": "format", "-f": "format" },
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
  if format != "deb" && format != "rpm" && format != "all" {
    raise Usage("unknown format \"\{format}\", expected deb, rpm or all")
  }
  if !@fs.path_exists(dir) {
    raise Failed("\"\{dir}\" does not exist")
  }
  let debs = if format == "rpm" { [] } else { package_files(dir, ".deb") }
  let rpms = if format == "deb" { [] } else { package_files(dir, ".rpm") }
  if debs.length() == 0 && rpms.length() == 0 {
    raise Failed("no \{format} packages found in \"\{dir}\"")
  }
  // Without SOURCE_DATE_EPOCH the dates come from the packages themselves,
  // so running the command twice gives the same files.
  let stamp = match source_date_epoch() {
    Some(t) => t
    None => {
      let mut newest = 0L
      for deb in debs {
        let t = @repo.deb_time(deb) catch { err => raise Failed("\{err}") }
        if t > newest {
          newest = t
        }
      }
      for rpm in rpms {
        let t = @repo.rpm_time(rpm) catch { err => raise Failed("\{err}") }
        if t > newest {
          newest = t
        }
      }
      newest
    }
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
    println(
      "apt: \{debs.length()} package(s); use `deb [trusted=yes] file:<dir> ./`",
    )
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
    println(
      "yum: \{rpms.length()} package(s); use a .repo file with baseurl=file://<dir> and gpgcheck=0",
    )
  }
  0
}
