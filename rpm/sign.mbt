///|
/// Signature header tag of an RSA signature over the main header
/// (`RPMSIGTAG_RSA`, "RSAHEADER").
const SIG_RSA : Int32 = 268

///|
/// Signature header tag of a DSA-family signature over the main header
/// (`RPMSIGTAG_DSA`, "DSAHEADER"); rpm files EdDSA signatures here too.
const SIG_DSA : Int32 = 267

///|
/// Sign an rpm the way `rpmsign --addsign` does: an OpenPGP v4 signature
/// (SHA-256) over the exact bytes of the main header is added to the
/// signature header, as tag 268 for an RSA key and tag 267 for an Ed25519
/// key. The main header and the payload are not touched, so the package
/// installs and verifies as before; an earlier signature is replaced.
///
/// The signature time is `created`, or the key's creation time if that is
/// later (see `SigningKey::signing_time`). The same package, key and time
/// always give the same bytes.
pub fn sign(
  data : BytesView,
  key : @sign.SigningKey,
  created~ : Int64,
) -> Bytes raise RpmError {
  let pkg = read(data)
  let signature = key.detached(
    pkg.header_bytes[:],
    created=key.signing_time(created),
  ) catch {
    err => raise RpmError::Invalid(field="signature", message="\{err}")
  }
  let tags = pkg.signature.tags.filter(t => t.id != SIG_RSA && t.id != SIG_DSA)
  tags.push({
    id: if key.is_rsa() {
      SIG_RSA
    } else {
      SIG_DSA
    },
    value: Bin(signature),
  })
  let signature_bytes = { region: pkg.signature.region, tags, }.encode()
  let out = Buffer(size_hint=data.length() + signature.length() + 64)
  out.write_bytes(data[0:96])
  out.write_bytes(signature_bytes)
  // The main header starts at an 8 byte boundary.
  out.write_bytes(Bytes::make((8 - signature_bytes.length() % 8) % 8, b'\x00'))
  out.write_bytes(pkg.header_bytes)
  out.write_bytes(pkg.payload)
  out.to_bytes()
}

///|
/// What a package says about its OpenPGP signature.
///
/// - `Unsigned`: the signature header has no RSA or DSA signature.
/// - `Signed`: signed by this key id (16 hexadecimal digits); not checked,
///   because no keyring was given.
/// - `Good`: the signature checks out against a key of the keyring.
/// - `Bad`: the signature is damaged, does not match the main header, or was
///   made by a key that is not in the keyring; the text says which.
pub(all) enum SignatureStatus {
  Unsigned
  Signed(key_id~ : String)
  Good(@sign.Verified)
  Bad(String)
} derive(Eq, Debug)

///|
/// Look at the OpenPGP signature of the main header, and check it against
/// `keyring` if one is given.
pub fn RpmPackage::signature_status(
  self : RpmPackage,
  keyring : @sign.PublicKeyring?,
) -> SignatureStatus {
  let signature = match
    (self.signature.get(SIG_RSA), self.signature.get(SIG_DSA)) {
    (Some(Bin(data)), _) => data
    (_, Some(Bin(data))) => data
    _ => return Unsigned
  }
  match keyring {
    None =>
      try {
        let info = @sign.signature_info(signature)
        Signed(key_id=info.key_id)
      } catch {
        err => Bad("\{err}")
      }
    Some(ring) =>
      Good(ring.verify_detached(self.header_bytes[:], signature)) catch {
        err => Bad("\{err}")
      }
  }
}
