///|
/// Read an xz variable-length integer (7 bits per byte, at most 9 bytes).
fn varint(data : BytesView, pos : Ref[Int32]) -> UInt64 raise CompressError {
  let mut value = 0UL
  for i in 0..<9 {
    if pos.val >= data.length() {
      raise Corrupt("xz: truncated")
    }
    let b = data[pos.val].to_uint64()
    pos.val += 1
    value = value | ((b & 0x7FUL) << (7 * i))
    if b < 0x80UL {
      if b == 0UL && i > 0 {
        raise Corrupt("xz: malformed number")
      }
      return value
    }
  }
  raise Corrupt("xz: malformed number")
}

///|
fn check_size(id : Int32) -> Int32 {
  if id == 0 {
    0
  } else {
    4 << ((id - 1) / 3)
  }
}

///|
/// Add up the sizes of the LZMA2 chunks starting at `start`, up to the end
/// marker. Returns the unpacked size and the position after the marker.
fn lzma2_size(
  data : BytesView,
  start : Int32,
) -> (UInt64, Int32) raise CompressError {
  let mut pos = start
  let mut total = 0UL
  while true {
    if pos >= data.length() {
      raise Corrupt("xz: truncated")
    }
    let control = data[pos].to_int()
    if control == 0 {
      return (total, pos + 1)
    }
    if control == 1 || control == 2 {
      if pos + 3 > data.length() {
        raise Corrupt("xz: truncated")
      }
      let size = (data[pos + 1].to_int() << 8) + data[pos + 2].to_int() + 1
      total += size.to_uint64()
      pos += 3 + size
    } else if control >= 0x80 {
      if pos + 5 > data.length() {
        raise Corrupt("xz: truncated")
      }
      let unpacked = ((control & 0x1F) << 16) +
        (data[pos + 1].to_int() << 8) +
        data[pos + 2].to_int() +
        1
      let packed = (data[pos + 3].to_int() << 8) + data[pos + 4].to_int() + 1
      total += unpacked.to_uint64()
      pos += 5 + packed + (if control >= 0xC0 { 1 } else { 0 })
    } else {
      raise Corrupt("xz: invalid LZMA2 chunk")
    }
    if pos > data.length() {
      raise Corrupt("xz: truncated")
    }
  }
  raise Corrupt("xz: unreachable")
}

///|
/// The size an xz file unpacks to, worked out from its block headers and
/// LZMA2 chunk headers without decoding any data. Several streams in a row
/// (with zero padding between them) are added together.
fn xz_unpacked_size(data : BytesView) -> UInt64 raise CompressError {
  let mut total = 0UL
  let mut pos = 0
  while true {
    if data.length() - pos < 12 || !starts_with(data[pos:], b"\xfd7zXZ\x00") {
      raise Corrupt("xz: bad stream header")
    }
    let check = check_size(data[pos + 7].to_int() & 0x0F)
    pos += 12
    // Blocks, then the index (which starts with a zero byte).
    while true {
      if pos >= data.length() {
        raise Corrupt("xz: truncated")
      }
      if data[pos] == b'\x00' {
        break
      }
      let header_size = (data[pos].to_int() + 1) * 4
      if pos + header_size > data.length() {
        raise Corrupt("xz: truncated")
      }
      let flags = data[pos + 1].to_int()
      let cursor = Ref(pos + 2)
      let header = data[0:pos + header_size]
      let packed_known = (flags & 0x40) != 0
      let packed = if packed_known { varint(header, cursor) } else { 0UL }
      if (flags & 0x80) != 0 {
        ignore(varint(header, cursor))
      }
      // The filter chain: only the last one (LZMA2) changes the size.
      let filters = (flags & 3) + 1
      for _ in 0..<filters {
        ignore(varint(header, cursor))
        let props = varint(header, cursor)
        cursor.val += props.to_int()
        if cursor.val > header.length() {
          raise Corrupt("xz: truncated")
        }
      }
      let payload = pos + header_size
      let end = if packed_known {
        if packed > (data.length() - payload).to_uint64() {
          raise Corrupt("xz: truncated")
        }
        let (size, _) = lzma2_size(data[0:payload + packed.to_int()], payload)
        total += size
        payload + packed.to_int()
      } else {
        let (size, after) = lzma2_size(data, payload)
        total += size
        after
      }
      pos = end + (4 - (end - pos) % 4) % 4 + check
      if pos > data.length() {
        raise Corrupt("xz: truncated")
      }
    }
    // Index: indicator, record count, records, padding, CRC32; then footer.
    let cursor = Ref(pos + 1)
    let records = varint(data, cursor)
    if records > data.length().to_uint64() {
      raise Corrupt("xz: bad index")
    }
    for _ in 0..<records.to_int() {
      ignore(varint(data, cursor))
      ignore(varint(data, cursor))
    }
    let index_len = cursor.val - pos
    pos = cursor.val + (4 - index_len % 4) % 4 + 4 + 12
    if pos > data.length() {
      raise Corrupt("xz: truncated")
    }
    // Zero padding in multiples of four, then maybe another stream.
    let mut next = pos
    while next < data.length() && data[next] == b'\x00' {
      next += 1
    }
    if next == data.length() {
      return total
    }
    if (next - pos) % 4 != 0 {
      raise Corrupt("xz: bad stream padding")
    }
    pos = next
  }
  raise Corrupt("xz: unreachable")
}
