///|
/// The name of the signature file inside the signature stream:
/// `.SIGN.RSA.<key_name>` for SHA-1, `.SIGN.RSA256.<key_name>` for SHA-256.
fn signature_entry_name(hash : @sign.RsaHash, key_name : String) -> String {
  match hash {
    Sha1 => ".SIGN.RSA.\{key_name}"
    Sha256 => ".SIGN.RSA256.\{key_name}"
  }
}

///|
fn check_key_name(key_name : String) -> Unit raise ApkError {
  if key_name == "" || key_name.contains("/") || key_name.length() > 80 {
    raise ApkError::Invalid(
      field="key name",
      message="must be a file name such as `mykey.rsa.pub`, at most 80 characters, without `/`",
    )
  }
}

///|
/// The signature stream that apk expects in front of a file it verifies:
/// a gzip-compressed tar (without end marker, like the control stream) with one
/// entry, `.SIGN.RSA256.<key_name>`, whose content is the RSA signature of
/// `content`. `key_name` is the name of the public key file that users put
/// in `/etc/apk/keys/`, for example `mykey.rsa.pub`.
pub fn signature_stream(
  content : BytesView,
  key : @sign.SigningKey,
  key_name~ : String,
  created~ : Int64,
  hash~ : @sign.RsaHash = Sha256,
) -> Bytes raise ApkError {
  check_key_name(key_name)
  let signature = key.rsa_sign(hash, content) catch {
    err => raise ApkError::Invalid(field="signature", message="\{err}")
  }
  let entry = @tar.Entry::file(
    signature_entry_name(hash, key_name),
    signature,
    mtime=created,
  )
  let tar = @tar.build_with_records([(entry, [])], end_marker=false) catch {
    err => raise ApkError::Invalid(field="signature", message="\{err}")
  }
  @compress.compress(tar, Gzip) catch {
    err => raise ApkError::Invalid(field="signature", message="\{err}")
  }
}

///|
/// Sign an Alpine package: a signature stream over the control stream is put in
/// front of it (an earlier signature is replaced), so that `apk add` accepts the
/// package without `--allow-untrusted` when the matching public key is in
/// `/etc/apk/keys/`. The control and data streams are not touched. The result
/// depends only on the package, the key, the key name and the time (never
/// earlier than the key itself, see `SigningKey::signing_time`).
pub fn sign(
  data : BytesView,
  key : @sign.SigningKey,
  key_name~ : String,
  created~ : Int64,
  hash~ : @sign.RsaHash = Sha256,
) -> Bytes raise ApkError {
  let pkg = read(data)
  let stream = signature_stream(
    pkg.control_packed[:],
    key,
    key_name~,
    created=key.signing_time(created),
    hash~,
  )
  Bytes::from_array([..stream, ..pkg.control_packed, ..pkg.data_packed])
}

///|
/// Sign an `APKINDEX.tar.gz` like `abuild-sign` does: the signature stream
/// is put in front of the index, and covers all of its bytes.
pub fn sign_index(
  index : BytesView,
  key : @sign.SigningKey,
  key_name~ : String,
  created~ : Int64,
  hash~ : @sign.RsaHash = Sha256,
) -> Bytes raise ApkError {
  let stream = signature_stream(
    index,
    key,
    key_name~,
    created=key.signing_time(created),
    hash~,
  )
  Bytes::from_array([..stream, ..index])
}

///|
/// What the package says about its signature, and whether it holds against
/// `keyring` (a PEM `.rsa.pub` file or an OpenPGP RSA key) if one is given.
pub fn ApkPackage::signature_status(
  self : ApkPackage,
  keyring : @sign.PublicKeyring?,
) -> @sign.SignatureStatus {
  if self.signature_files.is_empty() {
    return @sign.Unsigned
  }
  let mut last = "no RSA signature"
  for file in self.signature_files {
    let (name, content, mtime) = file
    let parsed = if name.has_prefix(".SIGN.RSA256.") {
      Some((@sign.RsaHash::Sha256, name[13:].to_owned()))
    } else if name.has_prefix(".SIGN.RSA.") {
      Some((@sign.RsaHash::Sha1, name[10:].to_owned()))
    } else {
      None
    }
    match (parsed, keyring) {
      (None, _) => last = "\{name}: only RSA signatures are supported"
      (Some((_, key_name)), None) => return @sign.Signed(key_id=key_name)
      (Some((hash, key_name)), Some(ring)) =>
        try {
          let who = ring.verify_rsa(hash, self.control_packed[:], content[:])
          return @sign.Good({
            fingerprint: who,
            key_id: key_name,
            created: mtime,
          })
        } catch {
          err => last = "\{name}: \{err}"
        }
    }
  }
  @sign.Bad(last)
}
