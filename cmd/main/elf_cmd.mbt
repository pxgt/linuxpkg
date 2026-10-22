///|
/// `linuxpkg elf FILE`: what the ELF headers of a file say (the part of
/// `inspect` that `readelf -h -l -d` also shows), as text or JSON.
fn cmd_elf(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(args, Map([]), { "--json": "json" })
  let path = match options.positional {
    [path] => path
    [] => raise Usage("elf needs the path of an executable or library")
    _ => raise Usage("elf takes exactly one file")
  }
  let info = @elf.parse(read_bytes(path)[:]) catch {
    err => raise Failed("\{path}: \{err}")
  }
  if options.flag("json") {
    println(info.to_json().stringify(indent=2))
  } else {
    println("\{path}: \{info.describe()}")
  }
  0
}
