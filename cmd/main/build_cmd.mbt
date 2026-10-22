///|
fn load_spec(
  config_path : String,
  allow_arch_mismatch~ : Bool = false,
) -> (@spec.PackageSpec, @spec.Config) raise CliError {
  let text = @fs.read_file_to_string(config_path) catch {
    err => raise Failed(describe_io(err, "cannot read \"\{config_path}\""))
  }
  let parsed = @spec.Config::parse(text) catch {
    err => raise Failed("\{config_path}: \{err}")
  }
  let config = if allow_arch_mismatch {
    { ..parsed, allow_arch_mismatch: true, }
  } else {
    parsed
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
  for warning in config.elf_warnings(files) {
    eprintln("linuxpkg: warning: \{warning}")
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
      "--sign-key": "sign_key",
      "--apk-key-name": "apk_key_name",
    },
    { "--allow-arch-mismatch": "allow_arch_mismatch" },
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
  let (spec, config) = load_spec(
    config_path,
    allow_arch_mismatch=options.flag("allow_arch_mismatch"),
  )
  // --sign-key wins over "sign_key" in the configuration, whose path is
  // relative to the configuration file.
  let key_path = match (options.value("sign_key"), config.sign_key) {
    (Some(path), _) => Some(path)
    (None, Some(path)) => Some(join_path(dirname(config_path), path))
    (None, None) => None
  }
  let key = match key_path {
    Some(path) => Some(load_signing_key(path))
    None => None
  }
  let key_name = match (options.value("apk_key_name"), config.apk_key_name) {
    (Some(name), _) => Some(name)
    (None, Some(name)) => Some(name)
    (None, None) => None
  }
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
    let unsigned = @rpm.build(spec, compression~) catch {
      err => raise Failed("\{config_path}: \{err}")
    }
    let rpm = match key {
      Some(key) =>
        @rpm.sign(unsigned, key, created=spec.mtime) catch {
          err => raise Failed("\{config_path}: \{err}")
        }
      None => unsigned
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
        match key {
          Some(key) => {
            let signature = key.detached(
              pkg[:],
              created=key.signing_time(spec.mtime),
            ) catch {
              err => raise Failed("\{config_path}: \{err}")
            }
            write_bytes(target + ".sig", signature)
            println("wrote \{target}.sig (\{signature.length()} bytes)")
          }
          None => ()
        }
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
      unsigned => {
        // Alpine only knows RSA signatures: an Ed25519 key signs the other
        // formats and leaves the apk unsigned (an error if apk was asked for).
        let signing = match key {
          Some(k) =>
            if k.is_rsa() {
              Some(k)
            } else if format == "apk" {
              raise Failed(
                "apk packages can only be signed with an RSA key, \{key_path.unwrap()} is an Ed25519 key",
              )
            } else {
              eprintln(
                "linuxpkg: the apk package is not signed: Alpine only supports RSA keys",
              )
              None
            }
          None => None
        }
        let pkg = match signing {
          Some(k) =>
            @apk.sign(
              unsigned,
              k,
              key_name=apk_key_name(k, key_name),
              created=spec.mtime,
            ) catch {
              err => raise Failed("\{config_path}: \{err}")
            }
          None => unsigned
        }
        let target = join_path(out_dir, @apk.file_name(spec))
        write_bytes(target, pkg)
        println("wrote \{target} (\{pkg.length()} bytes)")
      }
    }
  }
  0
}
