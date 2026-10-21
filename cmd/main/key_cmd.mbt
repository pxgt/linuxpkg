///|
/// `linuxpkg key apk-pub KEY` writes the Alpine public key of an RSA signing
/// key; `linuxpkg key info KEY` shows which key a file holds. Neither prints or
/// copies any secret part of the key.
fn cmd_key(args : Array[String]) -> Int32 raise CliError {
  let options = parse_options(
    args,
    { "--name": "name", "-n": "name", "--out": "out", "-o": "out" },
    Map([]),
  )
  match options.positional {
    ["info", path] => {
      let key = load_signing_key(path)
      println("fingerprint: \{key.fingerprint()}")
      println("key id:      \{key.key_id()}")
      if key.is_rsa() {
        println("algorithm:   RSA \{key.rsa_bits()}")
      } else {
        println("algorithm:   Ed25519")
      }
      println("created:     \{@repo.rfc2822(key.created())}")
      0
    }
    ["apk-pub", path] => {
      let key = load_signing_key(path)
      let pem = key.rsa_public_pem() catch {
        err => raise Failed("\{path}: \{err}")
      }
      let name = match options.value("name") {
        Some(name) =>
          if name.has_suffix(".rsa.pub") {
            name
          } else {
            name + ".rsa.pub"
          }
        None => apk_key_name(key, None)
      }
      let out_dir = match options.value("out") {
        Some(dir) => dir
        None => ""
      }
      ensure_dir(out_dir)
      let target = join_path(out_dir, name)
      write_bytes(target, @utf8.encode(pem))
      println("wrote \{target}; copy it to /etc/apk/keys/ on Alpine Linux")
      0
    }
    ["info"] | ["apk-pub"] =>
      raise Usage(
        "key \{options.positional[0]} needs the path of a private key",
      )
    [] => raise Usage("key needs a subcommand: apk-pub KEY or info KEY")
    [other, ..] =>
      raise Usage(
        "unknown key subcommand \"\{other}\", expected apk-pub or info",
      )
  }
}
