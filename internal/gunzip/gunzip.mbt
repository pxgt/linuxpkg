///|
/// Why a gzip stream could not be unpacked.
pub suberror GunzipError {
  /// The stream is damaged or truncated; the text comes from the decoder.
  Corrupt(String)
  /// The stream would unpack to more than the allowed number of bytes.
  TooLarge(Int32)
}

///|
const CHUNK : Int32 = 65536

///|
/// Unpack a gzip stream (several members are joined) without ever holding
/// more than `max_size` bytes of output, so a small hostile input cannot
/// exhaust memory. CRC and length are verified by the decoder.
///
/// # Example
/// ```mbt check
/// test {
///   let packed = @gzip.compress(b"hello")
///   assert_eq(@gunzip.decompress(packed, max_size=100), b"hello")
/// }
/// ```
pub fn decompress(
  data : BytesView,
  max_size~ : Int32,
) -> Bytes raise GunzipError {
  let decoder = @gzip.Decoder()
  let out = Buffer(size_hint=1024)
  let chunk : FixedArray[Byte] = FixedArray::make(CHUNK, b'\x00')
  let mut pos = 0
  while true {
    let status = decoder.step_into(data[pos:], chunk, end=true) catch {
      @gzip.GzipError::GzipError(_, message) => raise Corrupt(message)
    }
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    pos += consumed
    if out.length() + produced > max_size {
      raise TooLarge(max_size)
    }
    out.write_bytes(Bytes::from_array(chunk[0:produced]))
    match status {
      Done => break
      NeedMoreInput => raise Corrupt("gzip: input too short")
      NeedMoreOutput =>
        if produced == 0 && consumed == 0 {
          raise Corrupt("gzip: decoder made no progress")
        }
    }
  }
  out.to_bytes()
}
