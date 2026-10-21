///|
fn lookup(files : Array[(String, Bytes)], name : String) -> Bytes? {
  for file in files {
    if file.0 == name {
      return Some(file.1)
    }
  }
  None
}

///|
fn utf8_text(name : String, data : Bytes) -> String raise RepoError {
  @utf8.decode(data[:]) catch {
    _ => raise Invalid(file=name, message="is not valid UTF-8 text")
  }
}

///|
/// The signature files of an apt repository: `InRelease` (the `Release` file
/// as a cleartext-signed message) and `Release.gpg` (an armored detached
/// signature over the exact bytes of `Release`). `files` is the output of
/// `apt_index`. The signature time is `created`, or the key's own creation
/// time if that is later, so that a build time of 0 still gives a signature
/// that `gpgv` accepts.
pub fn sign_apt(
  files : Array[(String, Bytes)],
  key : @sign.SigningKey,
  created~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let release = match lookup(files, "Release") {
    Some(release) => release
    None =>
      raise Invalid(file="Release", message="the index has no Release file")
  }
  let time = key.signing_time(created)
  let clear = key.cleartext(utf8_text("Release", release), created=time) catch {
    err => raise Invalid(file="InRelease", message="\{err}")
  }
  let detached = key.detached_armored(release[:], created=time) catch {
    err => raise Invalid(file="Release.gpg", message="\{err}")
  }
  [
    ("InRelease", @utf8.encode(clear[:])),
    ("Release.gpg", @utf8.encode(detached[:])),
  ]
}

///|
/// The signature file of a dnf repository: `repodata/repomd.xml.asc`, an
/// armored detached signature over the exact bytes of `repodata/repomd.xml`.
/// `files` is the output of `yum_index`. The signature time is chosen as in
/// `sign_apt`.
pub fn sign_yum(
  files : Array[(String, Bytes)],
  key : @sign.SigningKey,
  created~ : Int64,
) -> Array[(String, Bytes)] raise RepoError {
  let repomd = match lookup(files, "repodata/repomd.xml") {
    Some(repomd) => repomd
    None =>
      raise Invalid(
        file="repodata/repomd.xml",
        message="the index has no repomd.xml file",
      )
  }
  let time = key.signing_time(created)
  let detached = key.detached_armored(repomd[:], created=time) catch {
    err => raise Invalid(file="repodata/repomd.xml.asc", message="\{err}")
  }
  [("repodata/repomd.xml.asc", @utf8.encode(detached[:]))]
}

///|
/// Check the signatures of an apt repository against the keys of `ring`:
/// `Release.gpg` and `InRelease` must both be present, both must verify, and
/// the text inside `InRelease` must be the `Release` file. Returns the
/// problems found, empty if everything is right.
pub fn check_apt_signature(
  files : Array[(String, Bytes)],
  ring : @sign.PublicKeyring,
) -> Array[String] {
  let problems : Array[String] = []
  guard lookup(files, "Release") is Some(release) else {
    return ["Release: missing"]
  }
  match lookup(files, "Release.gpg") {
    None => problems.push("Release.gpg: missing")
    Some(signature) =>
      try ring.verify_detached(release[:], signature) catch {
        err => problems.push("Release.gpg: \{err}")
      } noraise {
        _ => ()
      }
  }
  match lookup(files, "InRelease") {
    None => problems.push("InRelease: missing")
    Some(clear) =>
      try {
        let (text, _) = ring.verify_cleartext(utf8_text("InRelease", clear))
        if @utf8.encode(text[:]) != release {
          problems.push("InRelease: the signed text is not the Release file")
        }
      } catch {
        err => problems.push("InRelease: \{err}")
      }
  }
  problems
}

///|
/// Check `repodata/repomd.xml.asc` of a dnf repository against the keys of
/// `ring`. Returns the problems found, empty if the signature is right.
pub fn check_yum_signature(
  files : Array[(String, Bytes)],
  ring : @sign.PublicKeyring,
) -> Array[String] {
  guard lookup(files, "repodata/repomd.xml") is Some(repomd) else {
    return ["repodata/repomd.xml: missing"]
  }
  guard lookup(files, "repodata/repomd.xml.asc") is Some(signature) else {
    return ["repodata/repomd.xml.asc: missing"]
  }
  try ring.verify_detached(repomd[:], signature) catch {
    err => ["repodata/repomd.xml.asc: \{err}"]
  } noraise {
    _ => []
  }
}
