///|
const SAMPLE_CONFIG : String =
  #|{
  #|  "name": "myapp",
  #|  "version": "0.1.0",
  #|  "release": "1",
  #|  "arch": "amd64",
  #|  "maintainer": "Your Name <you@example.org>",
  #|  "description": "One line summary of myapp\nA longer description. Every line after the\nsummary is shown by the package manager.",
  #|  "homepage": "https://example.org/myapp",
  #|  "license": "Apache-2.0",
  #|  "section": "utils",
  #|  "depends": ["libc6 (>= 2.31)"],
  #|  "contents": [
  #|    { "src": "build/myapp", "dst": "/usr/bin/myapp", "mode": "0755" },
  #|    { "src": "myapp.conf", "dst": "/etc/myapp.conf", "type": "config" },
  #|    { "dst": "/var/lib/myapp", "type": "dir" }
  #|  ]
  #|}
  #|

///|
fn cmd_init(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    { "--bin": "bin", "--name": "name", "--arch": "arch" },
    { "--force": "force", "-f": "force", "--moon": "moon" },
  )
  if options.flag("moon") {
    return init_moon(options)
  }
  let path = match options.positional {
    [] => "linuxpkg.json"
    [path] => path
    _ => raise Usage("init takes at most one path")
  }
  if @fs.path_exists(path) && !options.flag("force") {
    raise Failed("\"\{path}\" already exists, use --force to overwrite it")
  }
  write_bytes(path, @utf8.encode(SAMPLE_CONFIG))
  println("wrote \{path}")
  println("Edit it, then run: linuxpkg build \{path}")
  0
}
