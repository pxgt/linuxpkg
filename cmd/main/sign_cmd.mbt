///|
fn is_armored(data : Bytes) -> Bool {
  let marker = "-----BEGIN PGP"
  if data.length() < marker.length() {
    return false
  }
  for i, c in marker {
    if data[i].to_int() != c.to_int() {
      return false
    }
  }
  true
}

///|
fn key_text(path : String, data : Bytes) -> String raise CliError {
  @utf8.decode(data[:]) catch {
    _ => raise Failed("\"\{path}\" is not a key file")
  }
}

///|
/// Read the private key of `--sign-key`: ASCII armor or binary OpenPGP data,
/// without a passphrase. The key itself is never printed.
fn load_signing_key(path : String) -> @sign.SigningKey raise CliError {
  let data = read_bytes(path)
  try {
    if is_armored(data) {
      @sign.SigningKey::from_armored(key_text(path, data))
    } else {
      @sign.SigningKey::from_bytes(data)
    }
  } catch {
    Failed(message) => raise Failed(message)
    err => raise Failed("\{path}: \{err}")
  }
}

///|
/// Read the public keys of `--keyring` (or the public halves of a private key
/// file): ASCII armor or binary OpenPGP data.
fn load_keyring(path : String) -> @sign.PublicKeyring raise CliError {
  let data = read_bytes(path)
  try {
    if is_armored(data) {
      @sign.PublicKeyring::from_armored(key_text(path, data))
    } else {
      @sign.PublicKeyring::from_bytes(data)
    }
  } catch {
    Failed(message) => raise Failed(message)
    err => raise Failed("\{path}: \{err}")
  }
}

///|
/// The signature time for a build: the build time, but never before the key
/// was made (a signature older than its key is rejected by `gpgv`).
fn signature_time(key : @sign.SigningKey, stamp : Int64) -> Int64 {
  if stamp > key.created() {
    stamp
  } else {
    key.created()
  }
}
