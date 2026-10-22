///|
/// `linuxpkg convert nfpm.yaml [--format deb|rpm|apk|arch] [-o linuxpkg.json]`:
/// the `linuxpkg.json` that builds what the nFPM configuration describes.
fn cmd_convert(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    { "--format": "format", "-f": "format", "--out": "out", "-o": "out" },
    { "--force": "force" },
  )
  let path = match options.positional {
    [path] => path
    [] =>
      raise Usage("convert needs the path of an nFPM configuration (nfpm.yaml)")
    _ => raise Usage("convert takes exactly one configuration file")
  }
  let format = match options.value("format") {
    Some("arch") => "archlinux"
    Some(f) => f
    None => ""
  }
  if format != "" &&
    format != "deb" &&
    format != "rpm" &&
    format != "apk" &&
    format != "archlinux" {
    raise Usage("unknown format \"\{format}\", expected deb, rpm, apk or arch")
  }
  let converted = convert_nfpm(path, format, [])
  // What is written must be a configuration linuxpkg accepts.
  ignore(
    @spec.Config::parse(converted.config.stringify()) catch {
      err => raise Failed("\{path}: \{err}")
    },
  )
  let text = converted.config.stringify(indent=2) + "\n"
  match options.value("out") {
    Some(target) => {
      if @fs.path_exists(target) && !options.flag("force") {
        raise Failed(
          "\"\{target}\" already exists, use --force to overwrite it",
        )
      }
      write_bytes(target, @utf8.encode(text))
      println("wrote \{target}")
    }
    None => println(text.trim_end().to_owned())
  }
  0
}
