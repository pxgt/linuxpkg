///|
fn options_of(args : Array[String]) -> Options raise CliError {
  parse_options(
    args,
    {
      "--format": "format",
      "-f": "format",
      "--out": "out",
      "-o": "out",
      "--compression": "compression",
      "-z": "compression",
    },
    { "--force": "force" },
  )
}

///|
fn options_error(args : Array[String]) -> String {
  try options_of(args) catch {
    Usage(message) => "usage: \{message}"
    Failed(message) => "failed: \{message}"
    Mismatch(message) => "mismatch: \{message}"
  } noraise {
    _ => "ok"
  }
}

///|
test "positional arguments and options are separated" {
  let options = options_of([
    "cfg.json", "--format", "deb", "-o", "dist", "--force", "extra",
  ])
  assert_eq(options.positional, ["cfg.json", "extra"])
  assert_eq(options.value("format"), Some("deb"))
  assert_eq(options.value("out"), Some("dist"))
  assert_eq(options.value("missing"), None)
  assert_true(options.flag("force"))
  assert_true(!options.flag("other"))
}

///|
test "options accept the name=value form" {
  let options = options_of(["--out=build/out", "--format=all", "cfg.json"])
  assert_eq(options.value("out"), Some("build/out"))
  assert_eq(options.value("format"), Some("all"))
  assert_eq(options.positional, ["cfg.json"])
}

///|
test "a dash alone and everything after -- is positional" {
  let options = options_of(["-", "--", "--force", "-o"])
  assert_eq(options.positional, ["-", "--force", "-o"])
  assert_true(!options.flag("force"))
}

///|
test "bad options are usage errors" {
  inspect(
    options_error(["--bogus"]),
    content="usage: unknown option \"--bogus\"",
  )
  inspect(
    options_error(["--out"]),
    content="usage: option \"--out\" needs a value",
  )
  inspect(
    options_error(["--force=yes"]),
    content="usage: unknown option \"--force=yes\"",
  )
  inspect(options_error(["-x"]), content="usage: unknown option \"-x\"")
}

///|
test "path helpers" {
  assert_eq(dirname("a/b/c.json"), "a/b")
  assert_eq(dirname("c.json"), "")
  assert_eq(dirname("/c.json"), "/")
  assert_eq(dirname("C:\\work\\c.json"), "C:\\work")
  assert_true(is_absolute("/etc/x"))
  assert_true(is_absolute("C:\\x"))
  assert_true(is_absolute("d:/x"))
  assert_true(!is_absolute("x/y"))
  assert_true(!is_absolute("1:/x"))
  assert_eq(join_path("", "x/y"), "x/y")
  assert_eq(join_path("a/b", "x"), "a/b/x")
  assert_eq(join_path("a/b/", "x"), "a/b/x")
  assert_eq(join_path("a/b", "/abs/x"), "/abs/x")
}

///|
test "exit codes of the front end" {
  assert_eq(run(["--version"]), 0)
  assert_eq(run(["-V"]), 0)
  assert_eq(run(["--help"]), 0)
  assert_eq(run([]), 1)
  assert_eq(run(["bogus"]), 1)
  assert_eq(run(["build"]), 1)
  assert_eq(run(["build", "a.json", "b.json"]), 1)
  assert_eq(run(["build", "a.json", "--format", "zip"]), 1)
  assert_eq(run(["build", "does-not-exist.json"]), 1)
  assert_eq(run(["init", "a", "b"]), 1)
}

///|
test "permission strings look like ls -l" {
  assert_eq(mode_string("file", "0644"), "-rw-r--r--")
  assert_eq(mode_string("file", "0755"), "-rwxr-xr-x")
  assert_eq(mode_string("dir", "0750"), "drwxr-x---")
  assert_eq(mode_string("symlink", "0777"), "lrwxrwxrwx")
  assert_eq(mode_string("file", "4755"), "-rwsr-xr-x")
  assert_eq(mode_string("file", "4644"), "-rwSr--r--")
  assert_eq(mode_string("dir", "1777"), "drwxrwxrwt")
  assert_eq(mode_string("dir", "1776"), "drwxrwxrwT")
  assert_eq(mode_string("dir", "2755"), "drwxr-sr-x")
}

///|
test "rendering a package report" {
  let report : Json = {
    "format": "deb",
    "name": "hello",
    "version": "1.0-1",
    "architecture": "all",
    "maintainer": "Jane <jane@example.org>",
    "homepage": null,
    "installed_size_kib": "1",
    "description": "Says hello\nSecond line",
    "depends": ["bash (>= 4.0)", "coreutils"],
    "conffiles": ["/etc/hello.conf"],
    "scripts": ["postinst"],
    "compression": { "control": "gzip", "data": "gzip" },
    "files": [
      {
        "path": "/usr/bin/hello",
        "type": "file",
        "mode": "0755",
        "owner": "root",
        "group": "root",
        "size": 37,
        "link": null,
      },
      {
        "path": "/usr/bin/hi",
        "type": "symlink",
        "mode": "0777",
        "owner": "root",
        "group": "root",
        "size": 0,
        "link": "hello",
      },
    ],
  }
  inspect(
    render_report(report),
    content=(
      #|Package:       hello
      #|Version:       1.0-1
      #|Architecture:  all
      #|Maintainer:    Jane <jane@example.org>
      #|Installed size: 1 KiB
      #|Depends:       bash (>= 4.0), coreutils
      #|Description:   Says hello
      #|               Second line
      #|Scripts:       postinst
      #|Config files:  /etc/hello.conf
      #|Compression:   control gzip, data gzip
      #|
      #|Files (2):
      #|  -rwxr-xr-x  root/root         37  /usr/bin/hello
      #|  lrwxrwxrwx  root/root          0  /usr/bin/hi -> hello
      #|
    ),
  )
}

///|
test "inspect and verify need exactly one existing file" {
  assert_eq(run(["inspect"]), 1)
  assert_eq(run(["inspect", "a", "b"]), 1)
  assert_eq(run(["inspect", "does-not-exist.deb"]), 1)
  assert_eq(run(["verify"]), 1)
  assert_eq(run(["verify", "does-not-exist.deb"]), 1)
}

///|
const CONFIG_JSON : String =
  #|{
  #|  "name": "tinytool", "version": "1.0", "arch": "all",
  #|  "maintainer": "T <t@example.org>", "description": "Tiny\nTool",
  #|  "mtime": 1700000000,
  #|  "compression": "xz",
  #|  "rpm": {"compression": "zstd"},
  #|  "contents": [{"src": "tool.sh", "dst": "/usr/bin/tool", "mode": "0755"}]
  #|}

///|
test "build picks the compression from the config, the command line wins" {
  let dir = "cli_compress_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  let config = dir + "/linuxpkg.json"
  let find = (out : String, suffix : String) => {
    @fs.read_dir(out).iter().any(name => name.has_suffix(suffix))
  }
  // From the configuration: deb uses the package-wide xz, rpm its own zstd.
  assert_eq(run(["build", config, "--out", dir + "/a"]), 0)
  assert_eq(run(["verify", dir + "/a/tinytool_1.0-1_all.deb"]), 0)
  assert_eq(run(["verify", dir + "/a/tinytool-1.0-1.noarch.rpm"]), 0)
  let deb = @deb.read(read_bytes(dir + "/a/tinytool_1.0-1_all.deb"))
  assert_eq(deb.data_compression, "xz")
  let rpm = @rpm.read(read_bytes(dir + "/a/tinytool-1.0-1.noarch.rpm"))
  assert_eq(rpm.compressor(), "zstd")
  // The command line overrides both.
  assert_eq(run(["build", config, "-z", "none", "--out", dir + "/b"]), 0)
  let deb = @deb.read(read_bytes(dir + "/b/tinytool_1.0-1_all.deb"))
  assert_eq(deb.data_compression, "none")
  let rpm = @rpm.read(read_bytes(dir + "/b/tinytool-1.0-1.noarch.rpm"))
  assert_eq(rpm.compressor(), "identity")
  assert_eq(run(["verify", dir + "/b/tinytool-1.0-1.noarch.rpm"]), 0)
  // Unknown names are usage errors.
  assert_eq(run(["build", config, "--compression", "bzip2"]), 1)
  assert_eq(run(["build", config, "--compression"]), 1)
  assert_true(find(dir + "/a", ".deb") && find(dir + "/b", ".rpm"))
  for sub in ["a", "b"] {
    for name in @fs.read_dir(dir + "/" + sub) {
      @fs.remove_file(dir + "/" + sub + "/" + name)
    }
    @fs.remove_dir(dir + "/" + sub)
  }
  @fs.remove_file(config)
  @fs.remove_file(dir + "/tool.sh")
  @fs.remove_dir(dir)
}

///|
test "repo writes apt and dnf metadata that the checks accept" {
  let dir = "cli_repo_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  let repo = dir + "/repo"
  assert_eq(run(["build", dir + "/linuxpkg.json", "--out", repo]), 0)
  assert_eq(run(["repo", repo]), 0)
  for name in ["Packages", "Packages.gz", "Packages.xz", "Release"] {
    assert_true(@fs.path_exists(repo + "/" + name))
  }
  let before = @fs.read_dir(repo + "/repodata")
  assert_eq(before.length(), 4)
  let release = read_bytes(repo + "/Release")
  // The date comes from the package, so a second run changes nothing.
  assert_eq(run(["repo", repo]), 0)
  assert_eq(read_bytes(repo + "/Release"), release)
  assert_eq(@fs.read_dir(repo + "/repodata"), before)
  // Only one format.
  assert_eq(run(["repo", repo, "--format", "deb"]), 0)
  assert_eq(run(["repo", repo, "-f", "rpm"]), 0)
  // Usage and input errors.
  assert_eq(run(["repo"]), 1)
  assert_eq(run(["repo", repo, dir]), 1)
  assert_eq(run(["repo", repo, "--format", "zip"]), 1)
  assert_eq(run(["repo", dir + "/missing"]), 1)
  assert_eq(run(["repo", dir]), 1)
  // A file that is not a package stops the command.
  write_bytes(repo + "/broken.deb", b"nope")
  assert_eq(run(["repo", repo]), 1)
  @fs.remove_file(repo + "/broken.deb")
  remove_tree(dir)
}

///|
test "arch builds, inspects and verifies an Arch Linux package" {
  let dir = "cli_arch_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  let config = dir + "/linuxpkg.json"
  // Only the Arch Linux package; the config asks for xz package-wide.
  assert_eq(run(["build", config, "--format", "arch", "--out", dir + "/a"]), 0)
  let target = dir + "/a/tinytool-1.0-1-any.pkg.tar.xz"
  assert_true(@fs.path_exists(target))
  assert_eq(run(["verify", target]), 0)
  assert_eq(run(["inspect", target]), 0)
  assert_eq(run(["inspect", target, "--json"]), 0)
  assert_eq(@arch.read(read_bytes(target)).compression, "xz")
  // `all` adds it to the deb and the rpm; --compression wins.
  assert_eq(run(["build", config, "-z", "gzip", "--out", dir + "/b"]), 0)
  assert_eq(@fs.read_dir(dir + "/b").length(), 4)
  assert_true(@fs.path_exists(dir + "/b/tinytool-1.0-r1.apk"))
  assert_true(@fs.path_exists(dir + "/b/tinytool-1.0-1-any.pkg.tar.gz"))
  // An architecture without an Arch Linux port is skipped by `all`, and an
  // error for `--format arch`.
  let s390 = CONFIG_JSON.replace(
    old="\"arch\": \"all\"",
    new="\"arch\": \"s390x\"",
  )
  write_bytes(dir + "/s390.json", @utf8.encode(s390))
  assert_eq(run(["build", dir + "/s390.json", "--out", dir + "/c"]), 0)
  // (deb, rpm and apk: Alpine does have an s390x port)
  assert_eq(@fs.read_dir(dir + "/c").length(), 3)
  assert_eq(
    run(["build", dir + "/s390.json", "--format", "arch", "--out", dir + "/c"]),
    1,
  )
  // A damaged package is a mismatch, something else is not a package.
  let data = read_bytes(target)
  write_bytes(dir + "/broken.pkg.tar.xz", data[0:data.length() / 2].to_owned())
  assert_eq(run(["verify", dir + "/broken.pkg.tar.xz"]), 2)
  write_bytes(dir + "/plain.txt", b"just text")
  assert_eq(run(["verify", dir + "/plain.txt"]), 1)
  for sub in ["a", "b", "c"] {
    for name in @fs.read_dir(dir + "/" + sub) {
      @fs.remove_file(dir + "/" + sub + "/" + name)
    }
    @fs.remove_dir(dir + "/" + sub)
  }
  for name in @fs.read_dir(dir) {
    @fs.remove_file(dir + "/" + name)
  }
  @fs.remove_dir(dir)
}

///|
test "apk builds, inspects and verifies an Alpine Linux package" {
  let dir = "cli_apk_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  let config = dir + "/linuxpkg.json"
  assert_eq(run(["build", config, "--format", "apk", "--out", dir + "/a"]), 0)
  let target = dir + "/a/tinytool-1.0-r1.apk"
  assert_true(@fs.path_exists(target))
  assert_eq(@fs.read_dir(dir + "/a").length(), 1)
  assert_eq(run(["verify", target]), 0)
  assert_eq(run(["inspect", target]), 0)
  assert_eq(run(["inspect", target, "--json"]), 0)
  // An architecture Alpine has no port for is an error for --format apk.
  let armel = CONFIG_JSON.replace(
    old="\"arch\": \"all\"",
    new="\"arch\": \"armel\"",
  )
  write_bytes(dir + "/armel.json", @utf8.encode(armel))
  assert_eq(
    run(["build", dir + "/armel.json", "--format", "apk", "--out", dir + "/c"]),
    1,
  )
  // A damaged .apk is a mismatch; a gzip-compressed Arch package is not an apk.
  let data = read_bytes(target)
  write_bytes(dir + "/broken.apk", data[0:data.length() / 2].to_owned())
  assert_eq(run(["verify", dir + "/broken.apk"]), 2)
  assert_eq(
    run(["build", config, "--format", "arch", "-z", "gzip", "--out", dir + "/g"]),
    0,
  )
  assert_eq(run(["verify", dir + "/g/tinytool-1.0-1-any.pkg.tar.gz"]), 0)
  for name in @fs.read_dir(dir + "/g") {
    @fs.remove_file(dir + "/g/" + name)
  }
  @fs.remove_dir(dir + "/g")
  @fs.remove_dir(dir + "/c")
  for name in @fs.read_dir(dir + "/a") {
    @fs.remove_file(dir + "/a/" + name)
  }
  @fs.remove_dir(dir + "/a")
  for name in @fs.read_dir(dir) {
    @fs.remove_file(dir + "/" + name)
  }
  @fs.remove_dir(dir)
}

///|
test "repo --sign-key writes signatures that verify, and bad keys stop the command" {
  let dir = "cli_signrepo_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  write_bytes(dir + "/key.asc", @utf8.encode(fx_ed_secret))
  write_bytes(dir + "/key.pub.asc", @utf8.encode(fx_ed_public))
  let repo = dir + "/repo"
  assert_eq(run(["build", dir + "/linuxpkg.json", "--out", repo]), 0)
  assert_eq(run(["repo", repo, "--sign-key", dir + "/key.asc"]), 0)
  let ring = load_keyring(dir + "/key.pub.asc")
  let release = read_bytes(repo + "/Release")
  assert_eq(
    ring.verify_detached(release[:], read_bytes(repo + "/Release.gpg")).fingerprint,
    "66A22F1760CE2ABB10060451E2F97F5A50BD0EB3",
  )
  let (text, _) = ring.verify_cleartext(
    @utf8.decode(read_bytes(repo + "/InRelease")),
  )
  assert_eq(@utf8.encode(text), release)
  let repomd = read_bytes(repo + "/repodata/repomd.xml")
  assert_true(
    ring.verify_detached(
      repomd[:],
      read_bytes(repo + "/repodata/repomd.xml.asc"),
    ).created >
    0L,
  )
  // A second run gives the same files, signatures included.
  let before = (
    read_bytes(repo + "/InRelease"),
    read_bytes(repo + "/Release.gpg"),
  )
  assert_eq(run(["repo", repo, "--sign-key", dir + "/key.asc"]), 0)
  assert_eq(read_bytes(repo + "/InRelease"), before.0)
  assert_eq(read_bytes(repo + "/Release.gpg"), before.1)
  // A binary key file works too.
  let binary = @armor.decode(fx_ed_secret).data()
  write_bytes(dir + "/key.gpg", binary)
  assert_eq(run(["repo", repo, "--sign-key", dir + "/key.gpg"]), 0)
  // A missing, empty or wrong key stops the command.
  assert_eq(run(["repo", repo, "--sign-key", dir + "/missing.asc"]), 1)
  write_bytes(dir + "/empty.asc", b"")
  assert_eq(run(["repo", repo, "--sign-key", dir + "/empty.asc"]), 1)
  assert_eq(run(["repo", repo, "--sign-key", dir + "/key.pub.asc"]), 1)
  assert_eq(run(["repo", repo, "--sign-key"]), 1)
  remove_tree(dir)
}

///|
fn remove_tree(dir : String) -> Unit raise {
  for name in @fs.read_dir(dir) {
    let path = dir + "/" + name
    if @fs.is_dir(path) {
      remove_tree(path)
    } else {
      @fs.remove_file(path)
    }
  }
  @fs.remove_dir(dir)
}

///|
fn with_suffix(dir : String, suffix : String) -> Array[String] raise {
  @fs.read_dir(dir).filter(name => name.has_suffix(suffix))
}

///|
test "build --sign-key signs rpm and Arch packages and verify --keyring checks them" {
  let dir = "cli_signpkg_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  write_bytes(dir + "/rsa.asc", @utf8.encode(fx_rsa_secret))
  write_bytes(dir + "/rsa.pub.asc", @utf8.encode(fx_rsa_public))
  write_bytes(dir + "/ed.pub.asc", @utf8.encode(fx_ed_public))
  let config = dir + "/linuxpkg.json"
  assert_eq(run(["build", config, "--out", dir + "/plain"]), 0)
  assert_eq(
    run([
      "build",
      config,
      "--out",
      dir + "/signed",
      "--sign-key",
      dir + "/rsa.asc",
    ]),
    0,
  )
  let rpm = dir + "/signed/tinytool-1.0-1.noarch.rpm"
  let plain_rpm = dir + "/plain/tinytool-1.0-1.noarch.rpm"
  let arch = dir + "/signed/" + with_suffix(dir + "/signed", ".pkg.tar.xz")[0]
  let plain_arch = dir +
    "/plain/" +
    with_suffix(dir + "/plain", ".pkg.tar.xz")[0]
  assert_true(@fs.path_exists(arch + ".sig"))
  assert_true(!@fs.path_exists(plain_arch + ".sig"))
  // Without a keyring: reported, not checked, exit status unchanged.
  assert_eq(run(["verify", rpm]), 0)
  assert_eq(run(["verify", arch]), 0)
  assert_eq(run(["verify", plain_rpm]), 0)
  // With the right keyring.
  assert_eq(run(["verify", rpm, "--keyring", dir + "/rsa.pub.asc"]), 0)
  assert_eq(run(["verify", arch, "--keyring", dir + "/rsa.pub.asc"]), 0)
  // The private key file works as a keyring too.
  assert_eq(run(["verify", rpm, "--keyring", dir + "/rsa.asc"]), 0)
  // Wrong key, unsigned package: exit status 2.
  assert_eq(run(["verify", rpm, "--keyring", dir + "/ed.pub.asc"]), 2)
  assert_eq(run(["verify", arch, "--keyring", dir + "/ed.pub.asc"]), 2)
  assert_eq(run(["verify", plain_rpm, "--keyring", dir + "/rsa.pub.asc"]), 2)
  assert_eq(run(["verify", plain_arch, "--keyring", dir + "/rsa.pub.asc"]), 2)
  // A damaged Arch signature, and a package changed after signing.
  let sig = read_bytes(arch + ".sig").to_array()
  sig[sig.length() - 5] = sig[sig.length() - 5] ^ 1
  write_bytes(dir + "/damaged.pkg.tar.xz", read_bytes(arch))
  write_bytes(dir + "/damaged.pkg.tar.xz.sig", Bytes::from_array(sig))
  assert_eq(
    run([
      "verify",
      dir + "/damaged.pkg.tar.xz",
      "--keyring",
      dir + "/rsa.pub.asc",
    ]),
    2,
  )
  // deb and apk packages are not signed one by one.
  let deb = dir + "/signed/tinytool_1.0-1_all.deb"
  assert_eq(run(["verify", deb]), 0)
  assert_eq(run(["verify", deb, "--keyring", dir + "/rsa.pub.asc"]), 1)
  // Unusable keys and options.
  assert_eq(run(["verify", rpm, "--keyring", dir + "/missing.asc"]), 1)
  assert_eq(run(["verify", rpm, "--keyring"]), 1)
  assert_eq(
    run([
      "build",
      config,
      "--sign-key",
      dir + "/missing.asc",
      "--out",
      dir + "/x",
    ]),
    1,
  )
  // "sign_key" in the configuration is relative to the configuration file.
  write_bytes(
    config,
    @utf8.encode(
      CONFIG_JSON.replace(
        old="\"mtime\"",
        new="\"sign_key\": \"rsa.asc\", \"mtime\"",
      ),
    ),
  )
  assert_eq(
    run(["build", config, "--format", "rpm", "--out", dir + "/viaconfig"]),
    0,
  )
  assert_eq(
    run([
      "verify",
      dir + "/viaconfig/tinytool-1.0-1.noarch.rpm",
      "--keyring",
      dir + "/rsa.pub.asc",
    ]),
    0,
  )
  // Repositories: signed by `repo`, checked as a directory.
  assert_eq(run(["verify", dir + "/signed"]), 1)
  assert_eq(run(["repo", dir + "/signed", "--sign-key", dir + "/rsa.asc"]), 0)
  assert_eq(run(["verify", dir + "/signed"]), 0)
  assert_eq(
    run(["verify", dir + "/signed", "--keyring", dir + "/rsa.pub.asc"]),
    0,
  )
  assert_eq(
    run(["verify", dir + "/signed", "--keyring", dir + "/ed.pub.asc"]),
    2,
  )
  assert_eq(run(["repo", dir + "/plain"]), 0)
  assert_eq(run(["verify", dir + "/plain"]), 0)
  assert_eq(
    run(["verify", dir + "/plain", "--keyring", dir + "/rsa.pub.asc"]),
    2,
  )
  write_bytes(dir + "/signed/Release", b"Origin: changed\n")
  assert_eq(
    run(["verify", dir + "/signed", "--keyring", dir + "/rsa.pub.asc"]),
    2,
  )
  remove_tree(dir)
}

///|
test "apk signing: build --sign-key, key apk-pub, verify --keyring" {
  let dir = "cli_signapk_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  write_bytes(dir + "/rsa.asc", @utf8.encode(fx_rsa_secret))
  write_bytes(dir + "/rsa.pub.asc", @utf8.encode(fx_rsa_public))
  write_bytes(dir + "/ed.asc", @utf8.encode(fx_ed_secret))
  let config = dir + "/linuxpkg.json"
  // The public key for /etc/apk/keys/.
  assert_eq(
    run(["key", "apk-pub", dir + "/rsa.asc", "--out", dir + "/keys"]),
    0,
  )
  assert_eq(
    run([
      "key",
      "apk-pub",
      dir + "/rsa.asc",
      "--name",
      "mine",
      "--out",
      dir + "/keys",
    ]),
    0,
  )
  let default_name = "linuxpkg-03d2e4b8fa9ac68f.rsa.pub"
  assert_true(@fs.path_exists(dir + "/keys/" + default_name))
  assert_eq(
    read_bytes(dir + "/keys/mine.rsa.pub"),
    read_bytes(dir + "/keys/" + default_name),
  )
  assert_eq(run(["key", "info", dir + "/rsa.asc"]), 0)
  assert_eq(run(["key", "info", dir + "/ed.asc"]), 0)
  // Only RSA keys make Alpine keys; usage errors.
  assert_eq(run(["key", "apk-pub", dir + "/ed.asc"]), 1)
  assert_eq(run(["key", "apk-pub"]), 1)
  assert_eq(run(["key"]), 1)
  assert_eq(run(["key", "frobnicate", dir + "/rsa.asc"]), 1)
  assert_eq(run(["key", "info", dir + "/missing.asc"]), 1)
  // Build and check.
  assert_eq(
    run([
      "build",
      config,
      "--format",
      "apk",
      "--sign-key",
      dir + "/rsa.asc",
      "--out",
      dir + "/s",
    ]),
    0,
  )
  let apk = dir + "/s/tinytool-1.0-r1.apk"
  assert_eq(run(["verify", apk]), 0)
  assert_eq(run(["verify", apk, "--keyring", dir + "/keys/mine.rsa.pub"]), 0)
  assert_eq(run(["verify", apk, "--keyring", dir + "/rsa.pub.asc"]), 0)
  assert_eq(run(["verify", apk, "--keyring", dir + "/rsa.asc"]), 0)
  let apk_pkg = @apk.read(read_bytes(apk))
  assert_eq(apk_pkg.signatures, [".SIGN.RSA256." + default_name])
  // A named key, from the configuration.
  assert_eq(
    run([
      "build",
      config,
      "--format",
      "apk",
      "--sign-key",
      dir + "/rsa.asc",
      "--apk-key-name",
      "mine.rsa.pub",
      "--out",
      dir + "/n",
    ]),
    0,
  )
  assert_eq(@apk.read(read_bytes(dir + "/n/tinytool-1.0-r1.apk")).signatures, [
    ".SIGN.RSA256.mine.rsa.pub",
  ])
  // A wrong key and an unsigned package fail with exit status 2.
  assert_eq(run(["verify", apk, "--keyring", dir + "/ed.asc"]), 2)
  assert_eq(run(["build", config, "--format", "apk", "--out", dir + "/u"]), 0)
  assert_eq(
    run([
      "verify",
      dir + "/u/tinytool-1.0-r1.apk",
      "--keyring",
      dir + "/keys/mine.rsa.pub",
    ]),
    2,
  )
  assert_eq(run(["verify", dir + "/u/tinytool-1.0-r1.apk"]), 0)
  // An Ed25519 key cannot sign apk packages: an error for --format apk, a note for all.
  assert_eq(
    run([
      "build",
      config,
      "--format",
      "apk",
      "--sign-key",
      dir + "/ed.asc",
      "--out",
      dir + "/e",
    ]),
    1,
  )
  assert_eq(
    run(["build", config, "--sign-key", dir + "/ed.asc", "--out", dir + "/e"]),
    0,
  )
  assert_eq(@apk.read(read_bytes(dir + "/e/tinytool-1.0-r1.apk")).signatures, [])
  assert_eq(
    run([
      "verify",
      dir + "/e/tinytool-1.0-1.noarch.rpm",
      "--keyring",
      dir + "/rsa.pub.asc",
    ]),
    2,
  )
  // Bad key names.
  assert_eq(
    run([
      "build",
      config,
      "--format",
      "apk",
      "--sign-key",
      dir + "/rsa.asc",
      "--apk-key-name",
      "a/b",
      "--out",
      dir + "/b",
    ]),
    1,
  )
  remove_tree(dir)
}

///|
test "repo writes Alpine and pacman repositories, signed or not" {
  let dir = "cli_repoapk_tmp"
  ensure_dir(dir)
  write_bytes(dir + "/linuxpkg.json", @utf8.encode(CONFIG_JSON))
  write_bytes(dir + "/tool.sh", b"#!/bin/sh\necho hi\n")
  write_bytes(dir + "/rsa.asc", @utf8.encode(fx_rsa_secret))
  write_bytes(dir + "/rsa.pub.asc", @utf8.encode(fx_rsa_public))
  write_bytes(dir + "/ed.asc", @utf8.encode(fx_ed_secret))
  write_bytes(dir + "/ed.pub.asc", @utf8.encode(fx_ed_public))
  let repo = dir + "/repo"
  assert_eq(run(["build", dir + "/linuxpkg.json", "--out", repo]), 0)
  // Unsigned.
  assert_eq(run(["repo", repo, "--format", "apk", "--name", "demo"]), 0)
  for name in ["x86_64", "aarch64", "noarch"] {
    assert_true(@fs.path_exists(repo + "/" + name + "/tinytool-1.0-r1.apk"))
  }
  assert_true(@fs.path_exists(repo + "/x86_64/APKINDEX.tar.gz"))
  assert_eq(run(["repo", repo, "--format", "arch", "--name", "demo"]), 0)
  for name in ["demo.db", "demo.db.tar.gz", "demo.files", "demo.files.tar.gz"] {
    assert_true(@fs.path_exists(repo + "/" + name))
  }
  assert_eq(run(["verify", repo]), 0)
  assert_eq(run(["verify", repo, "--keyring", dir + "/rsa.pub.asc"]), 2)
  // Signed with an RSA key: everything verifies with that key and only that key.
  assert_eq(
    run([
      "repo",
      repo,
      "--sign-key",
      dir + "/rsa.asc",
      "--name",
      "demo",
      "--apk-key-name",
      "mine.rsa.pub",
    ]),
    0,
  )
  assert_true(@fs.path_exists(repo + "/demo.db.sig"))
  assert_true(@fs.path_exists(repo + "/demo.files.tar.gz.sig"))
  assert_eq(run(["verify", repo]), 0)
  assert_eq(run(["verify", repo, "--keyring", dir + "/rsa.pub.asc"]), 0)
  assert_eq(run(["verify", repo, "--keyring", dir + "/ed.pub.asc"]), 2)
  let index_before = read_bytes(repo + "/x86_64/APKINDEX.tar.gz")
  // Reproducible.
  assert_eq(
    run([
      "repo",
      repo,
      "--sign-key",
      dir + "/rsa.asc",
      "--name",
      "demo",
      "--apk-key-name",
      "mine.rsa.pub",
    ]),
    0,
  )
  assert_eq(read_bytes(repo + "/x86_64/APKINDEX.tar.gz"), index_before)
  // The signed index is accepted as an index again, with its packages.
  assert_eq(
    run(["repo", repo, "--format", "apk", "--sign-key", dir + "/rsa.asc"]),
    0,
  )
  // An Ed25519 key: pacman is signed, apk is left out (an error when asked for alone).
  assert_eq(
    run([
      "repo",
      repo,
      "--sign-key",
      dir + "/ed.asc",
      "--format",
      "arch",
      "--name",
      "demo",
    ]),
    0,
  )
  assert_eq(
    run(["repo", repo, "--sign-key", dir + "/ed.asc", "--format", "apk"]),
    1,
  )
  assert_eq(
    run(["repo", repo, "--sign-key", dir + "/ed.asc", "--name", "demo"]),
    0,
  )
  // Changed after signing.
  write_bytes(repo + "/demo.db", b"changed")
  assert_eq(run(["verify", repo, "--keyring", dir + "/ed.pub.asc"]), 2)
  // Usage errors.
  assert_eq(run(["repo", repo, "--format", "zip"]), 1)
  assert_eq(run(["repo", repo, "--name"]), 1)
  assert_eq(run(["repo", repo, "--format", "arch", "--name", "bad name"]), 1)
  remove_tree(dir)
}
