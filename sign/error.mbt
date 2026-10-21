///|
/// Why a key could not be read, or a signature could not be made or checked.
///
/// - `Key`: the key data is damaged, or it is a kind this library does not
///   handle (only version 4 RSA and EdDSA keys are supported).
/// - `Locked`: the private key is protected by a passphrase; remove the
///   passphrase first (for example `gpg --export-secret-keys` of an
///   unprotected copy, or decrypt it in your CI job).
/// - `Invalid`: a signature, a cleartext message or an argument is malformed.
/// - `BadSignature`: the signature is well formed but does not match the data
///   or no key of the keyring made it.
pub(all) suberror SignError {
  Key(message~ : String)
  Locked
  Invalid(message~ : String)
  BadSignature(message~ : String)
} derive(Eq, Debug)

///|
pub impl Show for SignError with fn output(self, logger) {
  match self {
    Key(message~) => logger.write_string("key: \{message}")
    Locked =>
      logger.write_string(
        "key: the private key is protected by a passphrase; remove the passphrase first",
      )
    Invalid(message~) => logger.write_string(message)
    BadSignature(message~) => logger.write_string("bad signature: \{message}")
  }
}
