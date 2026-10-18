///|
/// Why a command stopped.
priv suberror CliError {
  /// The command line is wrong; the usage hint is printed.
  Usage(String)
  /// The command could not do its job.
  Failed(String)
}

///|
const USAGE : String =
  #|linuxpkg - build Debian and RPM packages without dpkg-deb or rpmbuild
  #|
  #|Usage:
  #|  linuxpkg build <config.json> [--format deb|rpm|all] [--out DIR]
  #|  linuxpkg init [PATH] [--force]
  #|  linuxpkg --version
  #|
  #|Commands:
  #|  build    Build packages described by a linuxpkg.json file.
  #|  init     Write an example linuxpkg.json to edit.
  #|
  #|Options:
  #|  -f, --format FORMAT  Package format to build: deb (default), rpm or all.
  #|  -o, --out DIR        Directory for the packages (default: current directory).
  #|      --force          Overwrite an existing file (init).
  #|  -h, --help           Show this help.
  #|  -V, --version        Show the version.
  #|
  #|Set SOURCE_DATE_EPOCH to a Unix timestamp to make builds reproducible when
  #|the configuration does not set "mtime".
  #|
  #|Exit status: 0 on success, 1 for usage or input errors.

///|
fn run(args : Array[String]) -> Int32 {
  match args {
    [] => {
      eprintln(USAGE)
      1
    }
    ["--help" | "-h" | "help", ..] => {
      println(USAGE)
      0
    }
    ["--version" | "-V" | "version", ..] => {
      println("linuxpkg \{@linuxpkg.VERSION}")
      0
    }
    [command, .. rest] =>
      try dispatch(command, rest.to_owned()) catch {
        Usage(message) => {
          eprintln("linuxpkg: \{message}")
          eprintln("Run `linuxpkg --help` for usage.")
          1
        }
        Failed(message) => {
          eprintln("linuxpkg: \{message}")
          1
        }
      } noraise {
        code => code
      }
  }
}

///|
fn dispatch(command : String, args : Array[String]) -> Int32 raise CliError {
  match command {
    "build" => cmd_build(args)
    "init" => cmd_init(args)
    _ => raise Usage("unknown command \"\{command}\"")
  }
}

///|
fn main {
  let argv = @env.args()
  // The first element is the program itself.
  let args = if argv.length() > 0 { argv[1:].to_owned() } else { [] }
  let code = run(args)
  if code != 0 {
    @sys.exit(code)
  }
}
