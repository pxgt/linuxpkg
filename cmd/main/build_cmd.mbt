///|
/// Is this file an nFPM configuration (`nfpm.yaml`)?
fn is_nfpm_config(path : String) -> Bool {
  path.has_suffix(".yaml") || path.has_suffix(".yml")
}

///|
/// What the nFPM reader may ask of this machine: environment variables and
/// files (relative to the current directory, like nFPM).
fn cli_host() -> @nfpm.Host {
  {
    getenv: name => @env.get_env_var(name),
    read_file: path => {
      try @fs.read_file_to_bytes(path) catch {
        _ => None
      } noraise {
        data => Some(data)
      }
    },
    list_dir: path => {
      let is_directory = try @fs.is_dir(path) catch {
        _ => false
      } noraise {
        yes => yes
      }
      if is_directory {
        try @fs.read_dir(path) catch {
          _ => None
        } noraise {
          names => Some(names.to_owned())
        }
      } else {
        None
      }
    },
  }
}

///|
/// Read an nFPM configuration for one packager and print what could not be
/// carried over. `printed` holds the warnings shown already, so that building
/// several formats does not repeat them.
fn convert_nfpm(
  config_path : String,
  format : String,
  printed : Array[String],
) -> @nfpm.Converted raise CliError {
  let text = @fs.read_file_to_string(config_path) catch {
    err => raise Failed(describe_io(err, "cannot read \"\{config_path}\""))
  }
  let converted = @nfpm.convert(text, cli_host(), format~) catch {
    err => raise Failed("\{config_path}: \{err}")
  }
  for warning in converted.warnings {
    if !printed.contains(warning) {
      printed.push(warning)
      eprintln("linuxpkg: warning: \{warning}")
    }
  }
  converted
}

///|
fn load_nfpm(
  config_path : String,
  format : String,
  printed : Array[String],
) -> @spec.Config raise CliError {
  let converted = convert_nfpm(config_path, format, printed)
  @spec.Config::parse(converted.config.stringify()) catch {
    err => raise Failed("\{config_path}: \{err}")
  }
}

///|
/// The configuration of `config_path` resolved to a package. `nfpm_format` is
/// set for an nFPM file: that packager's view of it, with files looked up
/// relative to the current directory (nFPM does so); otherwise the file is a
/// `linuxpkg.json` and its files are relative to it.
fn load_spec(
  config_path : String,
  allow_arch_mismatch~ : Bool = false,
  nfpm_format? : String,
  printed~ : Array[String] = [],
) -> (@spec.PackageSpec, @spec.Config) raise CliError {
  let (parsed, base) = match nfpm_format {
    Some(format) => (load_nfpm(config_path, format, printed), "")
    None => {
      let text = @fs.read_file_to_string(config_path) catch {
        err => raise Failed(describe_io(err, "cannot read \"\{config_path}\""))
      }
      let parsed = @spec.Config::parse(text) catch {
        err => raise Failed("\{config_path}: \{err}")
      }
      (parsed, dirname(config_path))
    }
  }
  let config = if allow_arch_mismatch {
    { ..parsed, allow_arch_mismatch: true, }
  } else {
    parsed
  }
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
    if !printed.contains(warning) {
      printed.push(warning)
      eprintln("linuxpkg: warning: \{warning}")
    }
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
  let allow_mismatch = options.flag("allow_arch_mismatch")
  let out_dir = match options.value("out") {
    Some(dir) => dir
    None => ""
  }
  if is_nfpm_config(config_path) {
    // One build per packager: nFPM's overrides differ for each of them.
    let printed : Array[String] = []
    let all = format == "all"
    let wanted = match format {
      "all" => ["deb", "rpm", "archlinux", "apk"]
      "arch" => ["archlinux"]
      other => [other]
    }
    let failures : Array[String] = []
    for packager in wanted {
      let own = if packager == "archlinux" { "arch" } else { packager }
      try {
        let (spec, config) = load_spec(
          config_path,
          allow_arch_mismatch=allow_mismatch,
          nfpm_format=packager,
          printed~,
        )
        build_formats(
          config_path,
          "",
          spec,
          config,
          own,
          !all,
          forced,
          options.value("sign_key"),
          options.value("apk_key_name"),
          out_dir,
        )
      } catch {
        Failed(message) =>
          if all {
            // The other packagers still get their turn.
            // The same complaint about the whole file is printed once.
            let text = message.replace_all(old=config_path + ": ", new="")
            if !printed.contains(text) {
              printed.push(text)
              eprintln("linuxpkg: \{own}: \{message}")
            }
            failures.push(own)
          } else {
            raise Failed(message)
          }
        other => raise other
      } noraise {
        _ => ()
      }
    }
    if failures.length() > 0 {
      raise Failed("no package for \{failures.join(", ")}")
    }
  } else {
    let (spec, config) = load_spec(
      config_path,
      allow_arch_mismatch=allow_mismatch,
    )
    build_formats(
      config_path,
      dirname(config_path),
      spec,
      config,
      format,
      format != "all",
      forced,
      options.value("sign_key"),
      options.value("apk_key_name"),
      out_dir,
    )
  }
  0
}

///|
/// Write the packages of `format` (`deb`, `rpm`, `arch`, `apk`, or `all`).
/// With `strict` a package that does not fit its format (no Arch Linux port
/// for the architecture, ...) is an error; otherwise it is skipped with a note.
/// `base` is the directory of the configuration, which `sign_key` is relative to.
fn build_formats(
  config_path : String,
  base : String,
  spec : @spec.PackageSpec,
  config : @spec.Config,
  format : String,
  strict : Bool,
  forced : @compress.Compression?,
  sign_option : String?,
  key_name_option : String?,
  out_dir : String,
) -> Unit raise CliError {
  // --sign-key wins over "sign_key" in the configuration, whose path is
  // relative to the configuration file.
  let key_path = match (sign_option, config.sign_key) {
    (Some(path), _) => Some(path)
    (None, Some(path)) => Some(join_path(base, path))
    (None, None) => None
  }
  let key = match key_path {
    Some(path) => Some(load_signing_key(path))
    None => None
  }
  let key_name = match (key_name_option, config.apk_key_name) {
    (Some(name), _) => Some(name)
    (None, Some(name)) => Some(name)
    (None, None) => None
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
        if strict {
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
        if strict {
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
            } else if strict {
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
}
