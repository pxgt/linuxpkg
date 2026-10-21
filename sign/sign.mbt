///|
/// SHA-256 over the parts, one after the other, without joining them first.
fn sha256_parts(parts : Array[BytesView]) -> Bytes {
  let hasher = @crypto.SHA256::new()
  for part in parts {
    hasher.update(part)
  }
  Bytes::from_iter(hasher.finalize().iter())
}

///|
/// The hash of the signed data followed by the hashed part of the signature
/// packet and its trailer (RFC 4880 section 5.2.4). Any hash algorithm.
fn digest_parts(hash : @primitives.HashId, parts : Array[BytesView]) -> Bytes {
  match hash {
    Sha256 => sha256_parts(parts)
    _ => {
      let out : Array[Byte] = []
      for part in parts {
        for b in part {
          out.push(b)
        }
      }
      hash.digest(Bytes::from_array(out)[:])
    }
  }
}

///|
fn u32_bytes(value : Int32) -> Bytes {
  Bytes::makei(4, i => (value >> (24 - i * 8)).to_byte())
}

///|
/// The signature packet (with its packet header) over `data`.
///
/// `parts` is the data in order; the hashed subpackets carry the creation
/// time and the issuer fingerprint, the unhashed one the issuer key id.
fn SigningKey::signature_packet(
  self : SigningKey,
  sig_type : @packet.SigType,
  parts : Array[BytesView],
  created : Int64,
) -> Bytes raise SignError {
  guard created >= 0L && created <= 0xFFFFFFFFL else {
    raise Invalid(
      message="the signature time \{created} does not fit in 32 bits",
    )
  }
  let key_id = self.fingerprint[12:20].to_owned()
  let issuer = Bytes::from_array([4]).add(self.fingerprint)
  let hash = @primitives.Sha256
  let sig : @packet.SignaturePacket = {
    version: 4,
    sig_type,
    pub_algo: self.public.algo(),
    hash_algo: hash.number(),
    hashed_subpackets: [
      {
        critical: false,
        sub_type: @packet.SIGSUB_CREATION_TIME,
        body: u32_bytes(created.to_int()),
      },
      {
        critical: false,
        sub_type: @packet.SIGSUB_ISSUER_FINGERPRINT,
        body: issuer,
      },
    ],
    unhashed_subpackets: [
      { critical: false, sub_type: @packet.SIGSUB_ISSUER_KEY_ID, body: key_id, },
    ],
    raw_hashed_area: Bytes::new(0),
    fast_hash: 0,
    salt: Bytes::new(0),
    sig_params: [],
  }
  let prefix = sig.hash_prefix()
  let trailer = @packet.signature_trailer(4, prefix.length())
  let all = parts.copy()
  all.push(prefix[:])
  all.push(trailer[:])
  let digest = digest_parts(hash, all)
  let params : Array[Bytes] = match (self.rsa, self.ed) {
    (Some(rsa), _) =>
      [
        rsa.pkcs1_v15_sign(hash, digest[:]) catch {
          e => raise Key(message="RSA signing failed: \{describe(e)}")
        },
      ]
    (None, Some(ed)) => {
      let raw = ed.sign(digest[:]) catch {
        e => raise Key(message="Ed25519 signing failed: \{describe(e)}")
      }
      [raw[0:32].to_owned(), raw[32:64].to_owned()]
    }
    (None, None) => raise Key(message="the key has no private part")
  }
  let fast = (digest[0].to_int() << 8) | digest[1].to_int()
  let signed = { ..sig, fast_hash: fast, sig_params: params, }
  @packet.serialize_packet(@packet.Signature, signed.to_body()[:])
}

///|
/// A binary detached signature (an OpenPGP signature packet) over `data`,
/// as written by `gpg --detach-sign`. `created` is the signature time in
/// seconds since 1970; pass the build time (`SOURCE_DATE_EPOCH`) to get the
/// same signature every run. RSA and Ed25519 signatures are deterministic.
pub fn SigningKey::detached(
  self : SigningKey,
  data : BytesView,
  created~ : Int64,
) -> Bytes raise SignError {
  self.signature_packet(@packet.BinaryDocument, [data], created)
}

///|
/// The same signature as `detached`, in ASCII armor
/// (`-----BEGIN PGP SIGNATURE-----`), like `gpg --armor --detach-sign`.
pub fn SigningKey::detached_armored(
  self : SigningKey,
  data : BytesView,
  created~ : Int64,
) -> String raise SignError {
  armor_signature(self.detached(data, created~))
}

///|
/// ASCII armor of a signature without a `Version:` line, which would make
/// the output depend on the program that wrote it.
fn armor_signature(data : Bytes) -> String {
  let buf = StringBuilder()
  buf.write_string("-----BEGIN PGP SIGNATURE-----\n\n")
  let b64 = @base64.encode(data[:])
  let mut i = 0
  while i < b64.length() {
    let stop = if i + 64 < b64.length() { i + 64 } else { b64.length() }
    buf.write_string(b64[i:stop].to_owned())
    buf.write_char('\n')
    i += 64
  }
  let crc = @armor.crc24(data[:])
  buf.write_char('=')
  buf.write_string(@base64.encode(u32_bytes(crc)[1:4]))
  buf.write_string("\n-----END PGP SIGNATURE-----\n")
  buf.to_string()
}

///|
/// The lines of a text without their line endings, the way a signature
/// sees them: `\r\n` and `\n` both end a line, and spaces, tabs and a
/// stray `\r` at the end of a line are not part of it (RFC 4880 section 7.1).
/// A final line without a line ending is still a line.
fn text_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let chars = text.to_array()
  let current = StringBuilder()
  let mut open = false
  for c in chars {
    if c == '\n' {
      lines.push(current.to_string())
      current.reset()
      open = false
    } else {
      current.write_char(c)
      open = true
    }
  }
  if open {
    lines.push(current.to_string())
  }
  lines.map(strip_trailing_space)
}

///|
fn strip_trailing_space(line : String) -> String {
  let chars = line.to_array()
  let mut end = chars.length()
  while end > 0 &&
        (
          chars[end - 1] == ' ' ||
          chars[end - 1] == '\t' ||
          chars[end - 1] == '\r'
        ) {
    end -= 1
  }
  if end == chars.length() {
    line
  } else {
    String::from_array(chars[0:end])
  }
}

///|
/// What is hashed for a cleartext signature: the lines joined by `\r\n`,
/// with no line ending after the last one.
fn canonical_text(lines : Array[String]) -> Bytes {
  @utf8.encode(lines.join("\r\n")[:])
}

///|
/// A cleartext-signed message (`-----BEGIN PGP SIGNED MESSAGE-----`), the
/// format of an apt `InRelease` file, like `gpg --clearsign` with SHA-256.
///
/// Line endings are written as `\n`, trailing spaces and tabs are kept, and
/// lines that start with a dash are escaped as `- -...`. The text always
/// ends with a line ending.
pub fn SigningKey::cleartext(
  self : SigningKey,
  text : String,
  created~ : Int64,
) -> String raise SignError {
  let lines = text_lines(text)
  let signature = self.signature_packet(
    @packet.CanonicalTextDocument,
    [canonical_text(lines.map(strip_trailing_space))[:]],
    created,
  )
  let buf = StringBuilder()
  buf.write_string("-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n\n")
  for line in raw_lines(text) {
    if line.has_prefix("-") {
      buf.write_string("- ")
    }
    buf.write_string(line)
    buf.write_char('\n')
  }
  buf.write_string(armor_signature(signature))
  buf.to_string()
}

///|
/// Like `text_lines`, but keeping spaces and tabs at the end of a line.
fn raw_lines(text : String) -> Array[String] {
  let lines : Array[String] = []
  let current = StringBuilder()
  let mut open = false
  for c in text.to_array() {
    if c == '\n' {
      lines.push(strip_cr(current.to_string()))
      current.reset()
      open = false
    } else {
      current.write_char(c)
      open = true
    }
  }
  if open {
    lines.push(strip_cr(current.to_string()))
  }
  lines
}

///|
fn strip_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[0:line.length() - 1].to_owned()
  } else {
    line
  }
}
