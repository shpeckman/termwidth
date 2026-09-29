# src/termwidth/utf8.cr
module TermWidth::Utf8
  REPLACEMENT = 0xFFFD_u32

  def self.sequence_length(lead : UInt8) : Int32
    if lead < 0x80_u8
      1
    elsif lead < 0xC2_u8
      1
    elsif lead < 0xE0_u8
      2
    elsif lead < 0xF0_u8
      3
    elsif lead < 0xF5_u8
      4
    else
      1
    end
  end

  def self.continuation?(byte : UInt8) : Bool
    (byte & 0xC0_u8) == 0x80_u8
  end

  def self.decode(bytes : Bytes, index : Int32) : Tuple(UInt32, Int32)
    n  = bytes.size
    b0 = bytes.unsafe_fetch(index)

    return {b0.to_u32, 1} if b0 < 0x80_u8
    return {REPLACEMENT, 1} if b0 < 0xC2_u8 || b0 > 0xF4_u8

    if b0 < 0xE0_u8
      return {REPLACEMENT, 1} if index + 1 >= n
      b1 = bytes.unsafe_fetch(index + 1)
      return {REPLACEMENT, 1} unless continuation?(b1)
      return {((b0 & 0x1F_u8).to_u32 << 6) | (b1 & 0x3F_u8).to_u32, 2}
    end

    if b0 < 0xF0_u8
      lo = b0 == 0xE0_u8 ? 0xA0_u8 : 0x80_u8
      hi = b0 == 0xED_u8 ? 0x9F_u8 : 0xBF_u8
      return {REPLACEMENT, 1} if index + 1 >= n
      b1 = bytes.unsafe_fetch(index + 1)
      return {REPLACEMENT, 1} if b1 < lo || b1 > hi
      return {REPLACEMENT, 2} if index + 2 >= n
      b2 = bytes.unsafe_fetch(index + 2)
      return {REPLACEMENT, 2} unless continuation?(b2)
      cp = ((b0 & 0x0F_u8).to_u32 << 12) | ((b1 & 0x3F_u8).to_u32 << 6) | (b2 & 0x3F_u8).to_u32
      return {cp, 3}
    end

    lo = b0 == 0xF0_u8 ? 0x90_u8 : 0x80_u8
    hi = b0 == 0xF4_u8 ? 0x8F_u8 : 0xBF_u8
    return {REPLACEMENT, 1} if index + 1 >= n
    b1 = bytes.unsafe_fetch(index + 1)
    return {REPLACEMENT, 1} if b1 < lo || b1 > hi
    return {REPLACEMENT, 2} if index + 2 >= n
    b2 = bytes.unsafe_fetch(index + 2)
    return {REPLACEMENT, 2} unless continuation?(b2)
    return {REPLACEMENT, 3} if index + 3 >= n
    b3 = bytes.unsafe_fetch(index + 3)
    return {REPLACEMENT, 3} unless continuation?(b3)

    cp = ((b0 & 0x07_u8).to_u32 << 18) | ((b1 & 0x3F_u8).to_u32 << 12) |
         ((b2 & 0x3F_u8).to_u32 << 6) | (b3 & 0x3F_u8).to_u32
    {cp, 4}
  end

  def self.encoded_length(cp : UInt32) : Int32
    if cp < 0x80_u32
      1
    elsif cp < 0x800_u32
      2
    elsif cp < 0x10000_u32
      3
    else
      4
    end
  end
end
