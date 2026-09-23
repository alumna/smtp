# Quoted-printable body encoder (RFC 2045, section 6.7).
# Writes straight to the IO. It does not build a String.
#
# Rules:
# - CRLF, LF, and a lone CR in the input become one CRLF (a hard line break).
# - Printable ASCII is literal, except "=".
# - Space and tab are literal, except before a line break or at the end (then =20 / =09).
# - Any other byte is =XX (upper-case hex). UTF-8 text becomes =XX triplets.
# - A "." at the start of a line is =2E. So no output line starts with ".",
#   and the SMTP DATA phase needs no dot-stuffing.
# - A line has at most 75 characters, then a soft break ("=" CRLF).
#   A soft break never splits an =XX triplet.
#
# The output always ends at the start of a line (CRLF last), or is empty.
module Alumna::SMTP::QuotedPrintable
  # Characters on one line before the soft break "=". 75 + "=" = 76 (RFC 2045 limit).
  MAX_LINE = 75

  HEX = "0123456789ABCDEF".to_slice

  CR    = 13_u8
  LF    = 10_u8
  SPACE = 32_u8
  TAB   =  9_u8
  DOT   = 46_u8
  EQUAL = 61_u8

  def self.write(io : IO, text : String) : Nil
    bytes = text.to_slice
    size = bytes.size
    column = 0
    index = 0
    while index < size
      byte = bytes[index]
      if byte == CR || byte == LF
        io << "\r\n"
        column = 0
        index += 1
        # CRLF is one break, not two.
        index += 1 if byte == CR && index < size && bytes[index] == LF
        next
      end

      width = token_width(bytes, index, column)
      if column + width > MAX_LINE
        io << "=\r\n"
        column = 0
        # The byte now starts a line. A "." must change to =2E.
        width = token_width(bytes, index, column)
      end

      if width == 1
        io.write_byte(byte)
      else
        io.write_byte(EQUAL)
        io.write_byte(HEX[byte >> 4])
        io.write_byte(HEX[byte & 0x0F])
      end
      column += width
      index += 1
    end
    io << "\r\n" if column > 0
  end

  # 1 when the byte is written as is, 3 when it is written as =XX.
  private def self.token_width(bytes : Bytes, index : Int32, column : Int32) : Int32
    byte = bytes[index]
    return 3 if byte == DOT && column == 0
    if byte == SPACE || byte == TAB
      following = index + 1
      return 3 if following == bytes.size
      next_byte = bytes[following]
      return 3 if next_byte == CR || next_byte == LF
      return 1
    end
    return 1 if byte >= 33_u8 && byte <= 126_u8 && byte != EQUAL
    3
  end
end
