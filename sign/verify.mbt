///|
priv struct PublicKey {
  packet : @packet.PublicKeyPacket
  fingerprint : Bytes
}

///|
/// One or more OpenPGP public keys, to check signatures against.
///
/// Read them from the output of `gpg --export` (binary) or `gpg --armor --export`.
/// Only version 4 RSA and EdDSA keys are kept; other keys in the same file are ignored.
pub struct PublicKeyring {
  priv keys : Array[PublicKey]
}

///|
/// Who made a signature that checked out.
pub(all) struct Verified {
  /// The 40 hexadecimal digits of the signing key's fingerprint, in capitals.
  fingerprint : String
  /// The 16 hexadecimal digits of the signing key's id, in capitals.
  key_id : String
  /// The signature time, in seconds since 1970.
  created : Int64
} derive(Eq, Debug)

///|
fn usable(packet : @packet.PublicKeyPacket) -> Bool {
  if packet.version() != 4 {
    return false
  }
  match packet.algo() {
    RsaEncryptOrSign | RsaSignOnly | EdDsaLegacy => true
    _ => false
  }
}

///|
/// Read public keys from ASCII armor; several armor blocks are allowed.
pub fn PublicKeyring::from_armored(
  text : String,
) -> PublicKeyring raise SignError {
  let blocks = @armor.decode_all(text) catch {
    e => raise Key(message="armor: \{describe(e)}")
  }
  let all : Array[PublicKey] = []
  for block in blocks {
    if block.armor_type() == @armor.PublicKey ||
      block.armor_type() == @armor.PrivateKey {
      all.append(PublicKeyring::from_bytes(block.data()).keys)
    }
  }
  if all.is_empty() {
    raise Key(message="no public key found")
  }
  { keys: all, }
}

///|
/// Read public keys from binary OpenPGP packets. The secret key packets of
/// a private key file are accepted too; their public halves are used.
pub fn PublicKeyring::from_bytes(data : Bytes) -> PublicKeyring raise SignError {
  let keys : Array[PublicKey] = []
  for packet in parse_packets(data[:]) {
    let key : @packet.PublicKeyPacket? = match packet.tag() {
      @packet.PublicKey | @packet.PublicSubkey =>
        Some(
          @packet.PublicKeyPacket::parse(packet.body()[:]) catch {
            e => raise Key(message="damaged public key: \{describe(e)}")
          },
        )
      @packet.SecretKey | @packet.SecretSubkey =>
        Some(
          (@packet.SecretKeyPacket::parse(packet.body()[:]) catch {
            e => raise Key(message="damaged private key: \{describe(e)}")
          }).public,
        )
      _ => None
    }
    match key {
      Some(k) if usable(k) =>
        keys.push({
          packet: k,
          fingerprint: k.fingerprint() catch {
            e => raise Key(message=describe(e))
          },
        })
      _ => ()
    }
  }
  if keys.is_empty() {
    raise Key(message="no usable public key (version 4 RSA or EdDSA) found")
  }
  { keys, }
}

///|
/// The fingerprints of the keys, 40 hexadecimal digits each, in capitals.
pub fn PublicKeyring::fingerprints(self : PublicKeyring) -> Array[String] {
  self.keys.map(k => hex_upper(k.fingerprint))
}

///|
fn key_verifies(
  key : @packet.PublicKeyPacket,
  hash : @primitives.HashId,
  digest : Bytes,
  params : Array[Bytes],
) -> Bool {
  let params_of_key = key.params()
  match key.algo() {
    EdDsaLegacy =>
      try {
        guard params.length() == 2 && params_of_key.length() == 2 else {
          return false
        }
        let point = params_of_key[1]
        guard point.length() == 33 && point[0] == b'\x40' else { return false }
        let r = @primitives.pad_left(params[0][:], 32)
        let s = @primitives.pad_left(params[1][:], 32)
        let public = @pki.ed25519_public_key(point[1:33])
        public.verify(digest[:], r.add(s)[:])
      } catch {
        _ => false
      }
    _ =>
      try {
        guard params.length() == 1 && params_of_key.length() == 2 else {
          return false
        }
        let rsa = @pki.RsaPublicKey::{
          n: big(params_of_key[0]),
          e: big(params_of_key[1]),
        }
        rsa.pkcs1_v15_verify(hash, digest[:], params[0][:])
      } catch {
        _ => false
      }
  }
}

///|
/// Check one signature packet body against the keys and the signed `parts`.
fn PublicKeyring::verify_packet(
  self : PublicKeyring,
  body : Bytes,
  expected : @packet.SigType,
  parts : Array[BytesView],
) -> Verified raise SignError {
  let sig = @packet.SignaturePacket::parse(body[:]) catch {
    e => raise Invalid(message="damaged signature: \{describe(e)}")
  }
  guard sig.version() == 4 else {
    raise Invalid(message="unsupported signature version \{sig.version()}")
  }
  guard sig.sig_type() == expected else {
    raise Invalid(
      message="unexpected signature type \{sig.sig_type().number()}",
    )
  }
  let hash = match @primitives.hash_id_of_number(sig.hash_algo()) {
    Some(hash) => hash
    None =>
      raise Invalid(message="unsupported hash algorithm \{sig.hash_algo()}")
  }
  let prefix = sig.hash_prefix()
  let all = parts.copy()
  all.push(prefix[:])
  all.push(@packet.signature_trailer(4, prefix.length())[:])
  let digest = digest_parts(hash, all)
  if sig.fast_hash() != ((digest[0].to_int() << 8) | digest[1].to_int()) {
    raise BadSignature(message="the data does not match the signature")
  }
  let issuer_fp = match
    @packet.find_subpacket(
      sig.hashed_subpackets(),
      @packet.SIGSUB_ISSUER_FINGERPRINT,
    ) {
    Some(b) if b.length() == 21 => Some(b[1:21].to_owned())
    _ => None
  }
  let issuer_id = match
    @packet.find_subpacket(
      sig.hashed_subpackets(),
      @packet.SIGSUB_ISSUER_KEY_ID,
    ) {
    Some(b) => Some(b)
    None =>
      @packet.find_subpacket(
        sig.unhashed_subpackets(),
        @packet.SIGSUB_ISSUER_KEY_ID,
      )
  }
  let candidates = self.keys.filter(k => {
    match (issuer_fp, issuer_id) {
      (Some(fp), _) => k.fingerprint == fp
      (None, Some(id)) => k.fingerprint[12:20].to_owned() == id
      (None, None) => true
    }
  })
  if candidates.is_empty() {
    let who = match (issuer_fp, issuer_id) {
      (Some(fp), _) => hex_upper(fp)
      (None, Some(id)) => hex_upper(id)
      (None, None) => "?"
    }
    raise BadSignature(message="signed by the unknown key \{who}")
  }
  for key in candidates {
    if key_verifies(key.packet, hash, digest, sig.sig_params()) {
      let created = match sig.creation_time() {
        Some(t) => t.to_int64() & 0xFFFFFFFFL
        None => 0L
      }
      return {
        fingerprint: hex_upper(key.fingerprint),
        key_id: hex_upper(key.fingerprint[12:20].to_owned()),
        created,
      }
    }
  }
  raise BadSignature(message="the data does not match the signature")
}

///|
fn signature_packets(signature : Bytes) -> Array[Bytes] raise SignError {
  let binary = if looks_armored(signature) {
    let text = @utf8.decode(signature[:]) catch {
      _ => raise Invalid(message="the signature is not valid text")
    }
    let block = @armor.decode(text) catch {
      e => raise Invalid(message="armor: \{describe(e)}")
    }
    guard block.armor_type() == @armor.Signature else {
      raise Invalid(message="the armor block is not a signature")
    }
    block.data()
  } else {
    signature
  }
  let bodies : Array[Bytes] = []
  for packet in parse_packets(binary[:]) {
    if packet.tag() == @packet.Signature {
      bodies.push(packet.body())
    }
  }
  if bodies.is_empty() {
    raise Invalid(message="no signature packet found")
  }
  bodies
}

///|
fn looks_armored(data : Bytes) -> Bool {
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
/// Check a detached signature (binary or armored, as `gpg --detach-sign`
/// writes it) over `data`. Succeeds if one of its signatures was made by a key
/// of the keyring; raises `BadSignature` if the data was changed or the key
/// is unknown.
pub fn PublicKeyring::verify_detached(
  self : PublicKeyring,
  data : BytesView,
  signature : Bytes,
) -> Verified raise SignError {
  let mut failure : SignError = BadSignature(message="no signature")
  for body in signature_packets(signature) {
    try self.verify_packet(body, @packet.BinaryDocument, [data]) catch {
      e => failure = e
    } noraise {
      verified => return verified
    }
  }
  raise failure
}

///|
/// Check a cleartext-signed message (an apt `InRelease` file) and return the
/// signed text, with its lines ending in `\n`, together with the signer.
pub fn PublicKeyring::verify_cleartext(
  self : PublicKeyring,
  message : String,
) -> (String, Verified) raise SignError {
  let lines = message.split("\n").map(l => strip_cr(l.to_owned())).collect()
  let begin = "-----BEGIN PGP SIGNED MESSAGE-----"
  guard lines.length() > 0 && strip_trailing_space(lines[0]) == begin else {
    raise Invalid(message="not a cleartext-signed message")
  }
  let mut i = 1
  while i < lines.length() && lines[i] != "" {
    i += 1
  }
  guard i < lines.length() else {
    raise Invalid(message="the header of the cleartext message is not closed")
  }
  i += 1
  let body : Array[String] = []
  let mut signature_at = -1
  while i < lines.length() {
    if strip_trailing_space(lines[i]) == "-----BEGIN PGP SIGNATURE-----" {
      signature_at = i
      break
    }
    body.push(
      if lines[i].has_prefix("- ") {
        lines[i][2:].to_owned()
      } else {
        lines[i]
      },
    )
    i += 1
  }
  guard signature_at >= 0 else {
    raise Invalid(message="the cleartext message has no signature")
  }
  let armored = lines[signature_at:].join("\n") + "\n"
  let mut failure : SignError = BadSignature(message="no signature")
  for sig_body in signature_packets(@utf8.encode(armored[:])) {
    try
      self.verify_packet(sig_body, @packet.CanonicalTextDocument, [
        canonical_text(body.map(strip_trailing_space))[:],
      ])
    catch {
      e => failure = e
    } noraise {
      verified => {
        let text = StringBuilder()
        for line in body {
          text.write_string(line)
          text.write_char('\n')
        }
        return (text.to_string(), verified)
      }
    }
  }
  raise failure
}

///|
/// What a signature says about itself, without checking it.
pub(all) struct SignatureInfo {
  /// The 16 hexadecimal digits of the signing key's id, in capitals.
  key_id : String
  /// The signature time, in seconds since 1970.
  created : Int64
} derive(Eq, Debug)

///|
/// Read who signed and when from the first signature in `signature` (binary
/// or armored) without checking it against any key.
pub fn signature_info(signature : Bytes) -> SignatureInfo raise SignError {
  let body = signature_packets(signature)[0]
  let sig = @packet.SignaturePacket::parse(body[:]) catch {
    e => raise Invalid(message="damaged signature: \{describe(e)}")
  }
  let key_id = match
    @packet.find_subpacket(
      sig.hashed_subpackets(),
      @packet.SIGSUB_ISSUER_FINGERPRINT,
    ) {
    Some(b) if b.length() == 21 => b[13:21].to_owned()
    _ =>
      match
        @packet.find_subpacket(
          sig.hashed_subpackets(),
          @packet.SIGSUB_ISSUER_KEY_ID,
        ) {
        Some(b) => b
        None =>
          match
            @packet.find_subpacket(
              sig.unhashed_subpackets(),
              @packet.SIGSUB_ISSUER_KEY_ID,
            ) {
            Some(b) => b
            None => raise Invalid(message="the signature names no issuer")
          }
      }
  }
  let created = match sig.creation_time() {
    Some(t) => t.to_int64() & 0xFFFFFFFFL
    None => 0L
  }
  { key_id: hex_upper(key_id), created, }
}
