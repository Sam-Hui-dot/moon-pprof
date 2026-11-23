///|
priv struct WireReader {
  bytes : Bytes
  mut pos : Int32
  end : Int32
}

///|
fn WireReader::new(bytes : Bytes, start : Int32, end : Int32) -> WireReader {
  { bytes, pos: start, end, }
}

///|
fn WireReader::eof(self : WireReader) -> Bool {
  self.pos >= self.end
}

///|
fn WireReader::read_varint(self : WireReader) -> UInt64 raise PprofError {
  let mut result : UInt64 = 0UL
  let mut shift = 0
  while shift < 64 {
    guard self.pos < self.end else {
      raise InvalidProtobuf("truncated varint at offset \{self.pos}")
    }
    let b = self.bytes[self.pos].to_uint64()
    self.pos += 1
    let low = b & 0x7FUL
    if shift == 63 && low > 1UL {
      raise InvalidProtobuf("varint overflow at offset \{self.pos - 1}")
    }
    result = result | (low << shift)
    if (b & 0x80UL) == 0UL {
      return result
    }
    shift += 7
  }
  raise InvalidProtobuf("varint exceeds 10 bytes at offset \{self.pos}")
}

///|
fn WireReader::read_int64(self : WireReader) -> Int64 raise PprofError {
  self.read_varint().reinterpret_as_int64()
}

///|
fn WireReader::read_bool(self : WireReader) -> Bool raise PprofError {
  self.read_varint() != 0UL
}

///|
fn WireReader::read_tag(self : WireReader) -> (Int32, Int32) raise PprofError {
  let tag = self.read_varint()
  let wire_type = (tag & 0x7UL).to_int()
  let field_number = (tag >> 3).to_int()
  guard field_number > 0 else {
    raise InvalidProtobuf("invalid protobuf field number 0")
  }
  (field_number, wire_type)
}

///|
fn WireReader::read_len_slice(
  self : WireReader,
) -> (Int32, Int32) raise PprofError {
  let len_u64 = self.read_varint()
  let remaining = (self.end - self.pos).to_uint64()
  guard len_u64 <= remaining else {
    raise InvalidProtobuf(
      "length-delimited field exceeds buffer (\{len_u64} > \{remaining})",
    )
  }
  let start = self.pos
  let end = start + len_u64.to_int()
  self.pos = end
  (start, end)
}

///|
fn WireReader::read_utf8(self : WireReader) -> String raise PprofError {
  let (start, end) = self.read_len_slice()
  decode_utf8_slice(self.bytes, start, end)
}

///|
fn WireReader::skip_field(
  self : WireReader,
  wire_type : Int32,
) -> Unit raise PprofError {
  match wire_type {
    0 => ignore(self.read_varint())
    1 => {
      guard self.pos + 8 <= self.end else {
        raise InvalidProtobuf("truncated 64-bit field at offset \{self.pos}")
      }
      self.pos += 8
    }
    2 => ignore(self.read_len_slice())
    5 => {
      guard self.pos + 4 <= self.end else {
        raise InvalidProtobuf("truncated 32-bit field at offset \{self.pos}")
      }
      self.pos += 4
    }
    other => raise InvalidProtobuf("unsupported protobuf wire type \{other}")
  }
}

///|
/// Decode a UTF-8 byte slice into a MoonBit `String`, replacing invalid sequences with U+FFFD.
fn decode_utf8_slice(bytes : Bytes, start : Int32, end : Int32) -> String {
  let out = StringBuilder()
  let mut i = start
  while i < end {
    let b0 = bytes[i].to_int()
    if b0 < 0x80 {
      out.write_char(Int32::unsafe_to_char(b0))
      i += 1
    } else if (b0 & 0xE0) == 0xC0 && i + 1 < end {
      let b1 = bytes[i + 1].to_int()
      if (b1 & 0xC0) == 0x80 {
        let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
        if cp >= 0x80 {
          out.write_char(Int32::unsafe_to_char(cp))
          i += 2
          continue
        }
      }
      out.write_char('\u{FFFD}')
      i += 1
    } else if (b0 & 0xF0) == 0xE0 && i + 2 < end {
      let b1 = bytes[i + 1].to_int()
      let b2 = bytes[i + 2].to_int()
      if (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 {
        let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
        if cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF) {
          out.write_char(Int32::unsafe_to_char(cp))
          i += 3
          continue
        }
      }
      out.write_char('\u{FFFD}')
      i += 1
    } else if (b0 & 0xF8) == 0xF0 && i + 3 < end {
      let b1 = bytes[i + 1].to_int()
      let b2 = bytes[i + 2].to_int()
      let b3 = bytes[i + 3].to_int()
      if (b1 & 0xC0) == 0x80 && (b2 & 0xC0) == 0x80 && (b3 & 0xC0) == 0x80 {
        let cp = ((b0 & 0x07) << 18) |
          ((b1 & 0x3F) << 12) |
          ((b2 & 0x3F) << 6) |
          (b3 & 0x3F)
        if cp >= 0x10000 && cp <= 0x10FFFF {
          out.write_char(Int32::unsafe_to_char(cp))
          i += 4
          continue
        }
      }
      out.write_char('\u{FFFD}')
      i += 1
    } else {
      out.write_char('\u{FFFD}')
      i += 1
    }
  }
  out.to_string()
}

///|
/// Encode a MoonBit `String` into UTF-8 bytes inside a `@buffer.Buffer`.
fn write_utf8(buf : Buffer, text : String) -> Unit {
  for ch in text {
    let cp = ch.to_int()
    if cp < 0x80 {
      buf.write_byte(cp.to_byte())
    } else if cp < 0x800 {
      buf.write_byte((0xC0 | (cp >> 6)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      buf.write_byte((0xE0 | (cp >> 12)).to_byte())
      buf.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    } else {
      buf.write_byte((0xF0 | (cp >> 18)).to_byte())
      buf.write_byte((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      buf.write_byte((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.write_byte((0x80 | (cp & 0x3F)).to_byte())
    }
  }
}

///|
fn write_varint(buf : Buffer, value : UInt64) -> Unit {
  let mut v = value
  while v >= 0x80UL {
    buf.write_byte(((v & 0x7FUL) | 0x80UL).to_byte())
    v = v >> 7
  }
  buf.write_byte(v.to_byte())
}

///|
fn write_tag(buf : Buffer, field_number : Int32, wire_type : Int32) -> Unit {
  write_varint(buf, (field_number.to_uint64() << 3) | wire_type.to_uint64())
}

///|
fn write_int64_field(buf : Buffer, field_number : Int32, value : Int64) -> Unit {
  if value != 0L {
    write_tag(buf, field_number, 0)
    write_varint(buf, value.reinterpret_as_uint64())
  }
}

///|
fn write_uint64_field(
  buf : Buffer,
  field_number : Int32,
  value : UInt64,
) -> Unit {
  if value != 0UL {
    write_tag(buf, field_number, 0)
    write_varint(buf, value)
  }
}

///|
fn write_bool_field(buf : Buffer, field_number : Int32, value : Bool) -> Unit {
  if value {
    write_tag(buf, field_number, 0)
    buf.write_byte(b'\x01')
  }
}

///|
fn write_bytes_field(
  buf : Buffer,
  field_number : Int32,
  payload : Bytes,
) -> Unit {
  write_tag(buf, field_number, 2)
  write_varint(buf, payload.length().to_uint64())
  buf.write_bytes(payload)
}

///|
fn write_string_field(
  buf : Buffer,
  field_number : Int32,
  value : String,
) -> Unit {
  let inner = Buffer()
  write_utf8(inner, value)
  write_bytes_field(buf, field_number, inner.contents())
}
