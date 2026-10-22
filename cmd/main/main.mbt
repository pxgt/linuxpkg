///|
/// Why a command stopped.
priv suberror CliError {
  /// The command line is wrong; the usage hint is printed.
  Usage(String)
  /// The command could not do its job.
  Failed(String)
  /// The package was read but failed an integrity check.
  Mismatch(String)
}

///|
const USAGE : String =
  #|linuxpkg - build Debian, RPM and Arch Linux packages without dpkg-deb or rpmbuild
  #|
  #|Usage:
  #|  linuxpkg build <config.json> [--format deb|rpm|arch|apk|all] [--compression C] [--sign-key KEY] [--out DIR]
  #|  linuxpkg inspect <package> [--json]      (.deb, .rpm, .apk or .pkg.tar.*)
  #|  linuxpkg verify <package|repository dir> [--keyring KEY]
  #|  linuxpkg repo <dir> [--format deb|rpm|all] [--sign-key KEY]
  #|  linuxpkg elf <file> [--json]
  #|  linuxpkg key apk-pub|info <private key> [--name NAME] [--out DIR]
  #|  linuxpkg init [PATH] [--force]
  #|  linuxpkg init --moon [DIR] [--bin PACKAGE] [--name NAME] [--arch ARCH]
  #|  linuxpkg --version
  #|
  #|Commands:
  #|  build    Build packages described by a linuxpkg.json file.
  #|  inspect  Show the metadata and files of a package.
  #|  verify   Check the checksums of a package.
  #|  repo     Write apt and dnf repository metadata for the packages in a directory.
  #|  elf      Show the architecture, linking, interpreter and libraries of an ELF file.
  #|  key      Export the Alpine public key (apk-pub) of an RSA signing key, or show
  #|           which key a file holds (info).
  #|  init     Write an example linuxpkg.json to edit, or (--moon) one for the
  #|           native executable of the MoonBit project in DIR.
  #|
  #|Options:
  #|  -f, --format FORMAT  Package format to build or index: deb, rpm, arch, apk or all
  #|                       (default; build skips arch and apk where they do not fit).
  #|  -z, --compression C  Payload compression: none, gzip, xz or zstd. Overrides
  #|                       the configuration (default: gzip).
  #|  -o, --out DIR        Directory for the packages (default: current directory).
  #|      --sign-key KEY    Sign with this OpenPGP private key (ASCII armor or binary, RSA or
  #|                       Ed25519, no passphrase): rpm packages, Arch packages (a .sig
  #|                       file next to them; build) and apt / dnf metadata (repo).
  #|      --apk-key-name N Name of the Alpine public key in apk signatures (build; default
  #|                       linuxpkg-<key id>.rsa.pub).
  #|      --keyring KEY    Public key(s) to check signatures against (verify): ASCII armor
  #|                       or binary. Packages and repositories that are not signed fail.
  #|      --allow-arch-mismatch  Build even if an ELF file is for another CPU than "arch" (build).
  #|      --json           Print machine readable JSON (inspect, elf).
  #|      --force          Overwrite an existing file (init).
  #|  -h, --help           Show this help.
  #|  -V, --version        Show the version.
  #|
  #|Set SOURCE_DATE_EPOCH to a Unix timestamp to make builds reproducible when
  #|the configuration does not set "mtime".
  #|
  #|Exit status: 0 on success, 1 for usage errors, unreadable or unsupported
  #|input, 2 when verify finds a damaged or tampered package.

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
        Mismatch(message) => {
          eprintln("linuxpkg: \{message}")
          2
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
    "inspect" => cmd_inspect(args)
    "verify" => cmd_verify(args)
    "repo" => cmd_repo(args)
    "key" => cmd_key(args)
    "elf" => cmd_elf(args)
    _ => raise Usage("unknown command \"\{command}\"")
  }
}

///|
fn main {
  let argv = @env.args()
  // The first element is the program itself; on the js backend it is node
  // followed by the script path.
  let skip = if argv.length() > 1 && argv[1].has_suffix(".js") { 2 } else { 1 }
  let args = if argv.length() >= skip { argv[skip:].to_owned() } else { [] }
  let code = run(args)
  if code != 0 {
    @sys.exit(code)
  }
}
