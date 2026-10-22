///|
/// A private OpenPGP key that can sign.
///
/// Read one with `from_armored` or `from_bytes`. Supported: version 4 keys,
/// RSA and EdDSA (curve ed25519), without a passphrase. Signatures are made
/// with SHA-256, so the same bytes in always give the same bytes out.
pub struct SigningKey {
  priv rsa : @pki.RsaPrivateKey?
  priv ed : @pki.Ed25519SecretKey?
  priv public : @packet.PublicKeyPacket
  priv fingerprint : Bytes
}

///|
fn describe(e : Error) -> String {
  "\{e}"
}

///|
fn parse_packets(data : BytesView) -> Array[@packet.RawPacket] raise SignError {
  @packet.parse_packets(data) catch {
    e => raise Key(message="not OpenPGP data: \{describe(e)}")
  }
}

///|
fn big(octets : Bytes) -> BigInt {
  BigInt::from_octets(octets[:], signum=1)
}

///|
/// Read a private key from its ASCII armor (`-----BEGIN PGP PRIVATE KEY BLOCK-----`).
///
/// # Example
/// Sign a text with a test-only Ed25519 key (public on purpose, worthless) and check it again.
/// The signature time is a parameter, so the output is always the same.
/// ```mbt check
/// test {
///   let key = @sign.SigningKey::from_armored(
///     (
///       #|-----BEGIN PGP PRIVATE KEY BLOCK-----
///       #|
///       #|lFgEatjHaRYJKwYBBAHaRw8BAQdAjBG+o/exTH7GU6taTgS7oeumg9VLGukMf99h
///       #|jujN4ZsAAP9tbT9TYF8gkR1ww0fRSMYgjxtumClkTEyXULz+UcRc5Q89tD5saW51
///       #|eHBrZyB0ZXN0LW9ubHkgZWQyNTUxOSA8dGVzdC1vbmx5LWVkMjU1MTlAZXhhbXBs
///       #|ZS5pbnZhbGlkPoiQBBMWCAA4FiEEZqIvF2DOKrsQBgRR4vl/WlC9DrMFAmrYx2kC
///       #|GwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQ4vl/WlC9DrOEXAD/X6kItwxk
///       #|CJdPFPcNwdCOk27LlqLsybor/h+uBOwbq9QBAPzIiLA7Bsmn5KnwD8Qg6nqqYdWc
///       #|UeepdrKKgtKKJ8sG
///       #|=sNFR
///       #|-----END PGP PRIVATE KEY BLOCK-----
///     ),
///   )
///   assert_eq(key.fingerprint(), "66A22F1760CE2ABB10060451E2F97F5A50BD0EB3")
///   let message = key.cleartext("hello\n", created=1800000000L)
///   assert_true(message.has_prefix("-----BEGIN PGP SIGNED MESSAGE-----"))
///   // The public halves of the key are enough to check the message.
///   let ring = @sign.PublicKeyring::from_armored(
///     (
///       #|-----BEGIN PGP PRIVATE KEY BLOCK-----
///       #|
///       #|lFgEatjHaRYJKwYBBAHaRw8BAQdAjBG+o/exTH7GU6taTgS7oeumg9VLGukMf99h
///       #|jujN4ZsAAP9tbT9TYF8gkR1ww0fRSMYgjxtumClkTEyXULz+UcRc5Q89tD5saW51
///       #|eHBrZyB0ZXN0LW9ubHkgZWQyNTUxOSA8dGVzdC1vbmx5LWVkMjU1MTlAZXhhbXBs
///       #|ZS5pbnZhbGlkPoiQBBMWCAA4FiEEZqIvF2DOKrsQBgRR4vl/WlC9DrMFAmrYx2kC
///       #|GwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQ4vl/WlC9DrOEXAD/X6kItwxk
///       #|CJdPFPcNwdCOk27LlqLsybor/h+uBOwbq9QBAPzIiLA7Bsmn5KnwD8Qg6nqqYdWc
///       #|UeepdrKKgtKKJ8sG
///       #|=sNFR
///       #|-----END PGP PRIVATE KEY BLOCK-----
///     ),
///   )
///   let (text, signer) = ring.verify_cleartext(message)
///   assert_eq(text, "hello\n")
///   assert_eq(signer.key_id, key.key_id())
/// }
/// ```
pub fn SigningKey::from_armored(text : String) -> SigningKey raise SignError {
  let block = @armor.decode(text) catch {
    e => raise Key(message="armor: \{describe(e)}")
  }
  guard block.armor_type() == @armor.PrivateKey else {
    raise Key(message="the armor block is not a private key block")
  }
  SigningKey::from_bytes(block.data())
}

///|
/// Read a private key from binary OpenPGP packets (what `gpg --export-secret-keys`
/// writes without `--armor`). The first secret key packet is used.
pub fn SigningKey::from_bytes(data : Bytes) -> SigningKey raise SignError {
  for packet in parse_packets(data[:]) {
    if packet.tag() == @packet.SecretKey {
      return SigningKey::from_secret_packet(packet.body())
    }
  }
  raise Key(message="no private key packet found")
}

///|
fn SigningKey::from_secret_packet(body : Bytes) -> SigningKey raise SignError {
  let secret = @packet.SecretKeyPacket::parse(body[:]) catch {
    e => raise Key(message="damaged private key packet: \{describe(e)}")
  }
  let public = secret.public
  guard public.version() == 4 else {
    raise Key(message="only version 4 keys are supported")
  }
  guard !secret.dummy else {
    raise Key(message="the secret part of this key is not stored")
  }
  guard secret.s2k_usage == 0 else { raise Locked }
  let fingerprint = public.fingerprint() catch {
    e => raise Key(message=describe(e))
  }
  let reader = @packet.Reader::new(secret.secret_material[:])
  match public.algo() {
    RsaEncryptOrSign | RsaSignOnly => {
      let params = public.params()
      guard params.length() == 2 else {
        raise Key(message="damaged RSA public key")
      }
      let rsa = try {
        let d = big(reader.read_mpi())
        let p = big(reader.read_mpi())
        let q = big(reader.read_mpi())
        let u = big(reader.read_mpi())
        @pki.RsaPrivateKey::{
          public: { n: big(params[0]), e: big(params[1]), },
          d,
          p,
          q,
          u,
        }
      } catch {
        e => raise Key(message="damaged RSA private key: \{describe(e)}")
      }
      { rsa: Some(rsa), ed: None, public, fingerprint, }
    }
    EdDsaLegacy => {
      let params = public.params()
      guard params.length() == 2 &&
        params[1].length() == 33 &&
        params[1][0] == b'\x40' else {
        raise Key(message="damaged EdDSA public key")
      }
      let ed = try {
        let seed = @primitives.pad_left(reader.read_mpi()[:], 32)
        let derived = @pki.ed25519_public_of_seed(seed[:])
        if derived.public != params[1][1:33].to_owned() {
          raise Key(message="the EdDSA private and public parts do not match")
        }
        @pki.Ed25519SecretKey::{ seed, public: derived.public, }
      } catch {
        Key(message~) => raise Key(message~)
        e => raise Key(message="damaged EdDSA private key: \{describe(e)}")
      }
      { rsa: None, ed: Some(ed), public, fingerprint, }
    }
    algo =>
      raise Key(
        message="unsupported key algorithm \{algo.number()} (only RSA and EdDSA are supported)",
      )
  }
}

///|
/// The 40 hexadecimal digits of the version 4 fingerprint, in capitals.
pub fn SigningKey::fingerprint(self : SigningKey) -> String {
  hex_upper(self.fingerprint)
}

///|
/// The 16 hexadecimal digits of the key id (the last 8 bytes of the fingerprint).
pub fn SigningKey::key_id(self : SigningKey) -> String {
  hex_upper(self.fingerprint[12:20].to_owned())
}

///|
/// When the key was made, in seconds since 1970. A signature must not be
/// older than its key, so callers that sign with a build time use the larger
/// of the two.
pub fn SigningKey::created(self : SigningKey) -> Int64 {
  self.public.creation_time().to_int64() & 0xFFFFFFFFL
}

///|
/// The time to write into a signature of something built at `build_time`:
/// the build time, but never earlier than the key itself, because `gpgv`,
/// `rpm` and `pacman` refuse a signature that is older than its key. This
/// keeps builds with `SOURCE_DATE_EPOCH=0` signable and reproducible.
pub fn SigningKey::signing_time(self : SigningKey, build_time : Int64) -> Int64 {
  let key_time = self.created()
  if build_time > key_time {
    build_time
  } else {
    key_time
  }
}

///|
/// `true` for an RSA key, `false` for an Ed25519 key.
pub fn SigningKey::is_rsa(self : SigningKey) -> Bool {
  self.rsa is Some(_)
}

///|
/// The size of the RSA modulus in bits, or 0 for an Ed25519 key.
pub fn SigningKey::rsa_bits(self : SigningKey) -> Int32 {
  match self.rsa {
    Some(rsa) => rsa.public.octet_length() * 8
    None => 0
  }
}

///|
fn hex_upper(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(bytes).to_upper()
}
