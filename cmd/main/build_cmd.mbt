///|
fn load_spec(
  config_path : String,
) -> (@spec.PackageSpec, @spec.Config) raise CliError {
  let text = @fs.read_file_to_string(config_path) catch {
    err => raise Failed(describe_io(err, "cannot read \"\{config_path}\""))
  }
  let config = @spec.Config::parse(text) catch {
    err => raise Failed("\{config_path}: \{err}")
  }
  let base = dirname(config_path)
  let files : Map[String, Bytes] = Map([])
  for source in config.sources() {
    files[source] = read_bytes(join_path(base, source))
  }
  let default_mtime = match source_date_epoch() {
    Some(t) => t
    None => 0L
  }
  let spec = config.resolve(files, default_mtime~) catch {
    err => raise Failed("\{config_path}: \{err}")
  }
  (spec, config)
}

///|
fn cmd_build(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    {
      "--format": "format",
      "-f": "format",
      "--out": "out",
      "-o": "out",
      "--compression": "compression",
      "-z": "compression",
    },
    Map([]),
  )
  let config_path = match options.positional {
    [path] => path
    [] => raise Usage("build needs the path of a linuxpkg.json")
    _ => raise Usage("build takes exactly one configuration file")
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
  let forced = match options.value("compression") {
    Some(name) =>
      match @compress.Compression::parse(name) {
        Some(c) => Some(c)
        None =>
          raise Usage(
            "unknown compression \"\{name}\", expected none, gzip, xz or zstd",
          )
      }
    None => None
  }
  let (spec, config) = load_spec(config_path)
  let out_dir = match options.value("out") {
    Some(dir) => dir
    None => ""
  }
  ensure_dir(out_dir)
  if format == "deb" || format == "all" {
    let compression = match forced {
      Some(c) => c
      None => config.deb_compression()
    }
    let deb = @deb.build(spec, compression~) catch {
      err => raise Failed("\{config_path}: \{err}")
    }
    let target = join_path(out_dir, @deb.file_name(spec))
    write_bytes(target, deb)
    println("wrote \{target} (\{deb.length()} bytes)")
  }
  if format == "rpm" || format == "all" {
    let compression = match forced {
      Some(c) => c
      None => config.rpm_compression()
    }
    let rpm = @rpm.build(spec, compression~) catch {
      err => raise Failed("\{config_path}: \{err}")
    }
    let target = join_path(out_dir, @rpm.file_name(spec))
    write_bytes(target, rpm)
    println("wrote \{target} (\{rpm.length()} bytes)")
  }
  if format == "arch" || format == "all" {
    let compression = match forced {
      Some(c) => c
      None => config.arch_compression()
    }
    // `all` is the Debian and RPM families plus Arch Linux where the package
    // fits Arch (it has no port of every architecture, and its release must
    // be a number); a package that does not is skipped with a note.
    try @arch.build(spec, compression~) catch {
      err =>
        if format == "arch" {
          raise Failed("\{config_path}: \{err}")
        } else {
          eprintln("linuxpkg: no Arch Linux package: \{err}")
        }
    } noraise {
      pkg => {
        let target = join_path(out_dir, @arch.file_name(spec, compression~))
        write_bytes(target, pkg)
        println("wrote \{target} (\{pkg.length()} bytes)")
      }
    }
  }
  if format == "apk" || format == "all" {
    // apk packages are always gzip, so --compression does not apply.
    try @apk.build(spec) catch {
      err =>
        if format == "apk" {
          raise Failed("\{config_path}: \{err}")
        } else {
          eprintln("linuxpkg: no Alpine Linux package: \{err}")
        }
    } noraise {
      pkg => {
        let target = join_path(out_dir, @apk.file_name(spec))
        write_bytes(target, pkg)
        println("wrote \{target} (\{pkg.length()} bytes)")
      }
    }
  }
  0
}
