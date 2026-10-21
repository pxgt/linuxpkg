///|
/// The hash of a plain RSA signature (PKCS#1 v1.5), as Alpine's package
/// tools use them: `Sha1` for `.SIGN.RSA.`, `Sha256` for `.SIGN.RSA256.`.
pub(all) enum RsaHash {
  Sha1
  Sha256
} derive(Eq, Debug)

///|
fn RsaHash::id(self : RsaHash) -> @primitives.HashId {
  match self {
    Sha1 => @primitives.Sha1
    Sha256 => @primitives.Sha256
  }
}

///|
/// A plain RSA signature (PKCS#1 v1.5, like `openssl dgst -sha256 -sign`) of
/// `data`, without any OpenPGP packet around it. Only for RSA keys.
pub fn SigningKey::rsa_sign(
  self : SigningKey,
  hash : RsaHash,
  data : BytesView,
) -> Bytes raise SignError {
  guard self.rsa is Some(rsa) else {
    raise Key(message="only RSA keys can make this kind of signature")
  }
  let digest = hash.id().digest(data)
  rsa.pkcs1_v15_sign(hash.id(), digest[:]) catch {
    e => raise Key(message="RSA signing failed: \{describe(e)}")
  }
}

///|
fn der_length(n : Int32) -> Bytes {
  if n < 128 {
    Bytes::from_array([n.to_byte()])
  } else if n < 256 {
    Bytes::from_array([b'\x81', n.to_byte()])
  } else if n < 65536 {
    Bytes::from_array([b'\x82', (n >> 8).to_byte(), n.to_byte()])
  } else {
    Bytes::from_array([
      b'\x83',
      (n >> 16).to_byte(),
      (n >> 8).to_byte(),
      n.to_byte(),
    ])
  }
}

///|
fn der(tag : Int32, content : Bytes) -> Bytes {
  Bytes::from_array([tag.to_byte()])
  .add(der_length(content.length()))
  .add(content)
}

///|
/// A DER INTEGER from big-endian bytes without leading zeros.
fn der_integer(value : Bytes) -> Bytes {
  let body = if value.length() == 0 || value[0] >= b'\x80' {
    Bytes::from_array([b'\x00']).add(value)
  } else {
    value
  }
  der(0x02, body)
}

///|
/// The public half of an RSA key as a PEM `PUBLIC KEY` block (a
/// SubjectPublicKeyInfo), the format of the `.rsa.pub` files in
/// `/etc/apk/keys/` and of `openssl rsa -pubout`.
pub fn SigningKey::rsa_public_pem(self : SigningKey) -> String raise SignError {
  guard self.rsa is Some(rsa) else {
    raise Key(message="only RSA keys can be exported as an Alpine key")
  }
  let params = self.public.params()
  let rsa_key = der(0x30, der_integer(params[0]).add(der_integer(params[1])))
  ignore(rsa)
  let algorithm = der(
    0x30,
    der(0x06, b"\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01").add(b"\x05\x00"),
  )
  let spki = der(
    0x30,
    algorithm.add(der(0x03, Bytes::from_array([b'\x00']).add(rsa_key))),
  )
  let b64 = @base64.encode(spki[:])
  let out = StringBuilder()
  out.write_string("-----BEGIN PUBLIC KEY-----\n")
  let mut i = 0
  while i < b64.length() {
    let stop = if i + 64 < b64.length() { i + 64 } else { b64.length() }
    out.write_string(b64[i:stop].to_owned())
    out.write_char('\n')
    i += 64
  }
  out.write_string("-----END PUBLIC KEY-----\n")
  out.to_string()
}
