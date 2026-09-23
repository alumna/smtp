# Header values for the SMTP message (RFC 5322 and RFC 2047).
# All methods write to the IO. They do not build a String.
#
# Mail.new (Alumna 0.10.1+) already rejects CR and LF in from, to, reply_to,
# and subject. So a value here cannot add a header line.
module Alumna::SMTP::Header
  # Recommended line length (RFC 5322 section 2.1.1). Folding aims for this.
  FOLD_AT = 78
  # Hard line limit without CRLF (RFC 5322 section 2.1.1).
  LINE_LIMIT = 998
  # UTF-8 bytes in one encoded word. 39 bytes = 52 base64 characters.
  # "=?UTF-8?B?" + 52 + "?=" = 64, so "Subject: " + one word stays under 76.
  WORD_BYTES = 39

  SPACE = 32_u8
  TAB   =  9_u8
  QUOTE = 34_u8
  LESS  = 60_u8
  MORE  = 62_u8
  AT    = 64_u8

  # Writes "Name: value" CRLF for free text (Subject).
  # Printable ASCII is folded at spaces. Other text uses RFC 2047 encoded words.
  # A word too long to fold also uses encoded words, so no line passes LINE_LIMIT.
  def self.write_text(io : IO, name : String, value : String) : Nil
    io << name << ": "
    bytes = value.to_slice
    column = name.bytesize + 2
    if plain?(bytes) && longest_word(bytes) + column <= LINE_LIMIT
      write_folded(io, bytes, column)
    else
      write_encoded(io, bytes)
    end
    io << "\r\n"
  end

  # Writes "Name: address, address" CRLF. Each address after the first is on
  # its own folded line, so a long list does not make a long line.
  def self.write_addresses(io : IO, name : String, values : Array(String)) : Nil
    io << name << ": "
    values.each_with_index do |value, index|
      io << ",\r\n " if index > 0
      write_address(io, value)
    end
    io << "\r\n"
  end

  # Writes "Name: address" CRLF.
  def self.write_address(io : IO, name : String, value : String) : Nil
    io << name << ": "
    write_address(io, value)
    io << "\r\n"
  end

  # The bare address for the envelope and for the Message-ID domain.
  # "Name <a@b>" gives "a@b". A value without "<...>" at the end is the address.
  # The result is a view of the value bytes. It does not allocate.
  def self.address(value : String) : Bytes
    bytes = value.to_slice
    start = angle_start(bytes)
    return bytes unless start
    bytes[start + 1, bytes.size - start - 2]
  end

  # The part after the last "@" of the bare address. Empty when there is no "@".
  def self.domain(value : String) : Bytes
    bytes = address(value)
    at = bytes.rindex(AT)
    return Bytes.empty unless at
    bytes[at + 1, bytes.size - at - 1]
  end

  # One address as given. A display name that is not printable ASCII is
  # encoded (RFC 2047). Quotes around that name are removed first, because an
  # encoded word must not be inside a quoted string.
  private def self.write_address(io : IO, value : String) : Nil
    bytes = value.to_slice
    start = angle_start(bytes)
    unless start
      io.write(bytes)
      return
    end
    display = trim(bytes[0, start])
    if plain?(display)
      io.write(bytes)
      return
    end
    if display.size >= 2 && display[0] == QUOTE && display[display.size - 1] == QUOTE
      display = display[1, display.size - 2]
    end
    write_encoded(io, display)
    io.write_byte(SPACE)
    io.write(bytes[start, bytes.size - start])
  end

  # Index of the "<" that opens the address, when the value ends with ">".
  private def self.angle_start(bytes : Bytes) : Int32?
    return nil if bytes.empty? || bytes[bytes.size - 1] != MORE
    bytes.rindex(LESS)
  end

  # True when every byte is printable ASCII, space, or tab.
  private def self.plain?(bytes : Bytes) : Bool
    bytes.all? { |byte| (byte >= 32_u8 && byte <= 126_u8) || byte == TAB }
  end

  # The longest run of bytes without a space.
  private def self.longest_word(bytes : Bytes) : Int32
    longest = 0
    run = 0
    bytes.each do |byte|
      if byte == SPACE
        run = 0
      else
        run += 1
        longest = run if run > longest
      end
    end
    longest
  end

  # Removes spaces and tabs at both ends. A view, no allocation.
  private def self.trim(bytes : Bytes) : Bytes
    first = 0
    last = bytes.size
    while first < last && (bytes[first] == SPACE || bytes[first] == TAB)
      first += 1
    end
    while last > first && (bytes[last - 1] == SPACE || bytes[last - 1] == TAB)
      last -= 1
    end
    bytes[first, last - first]
  end

  # Writes ASCII text. Adds CRLF before a space when the next word would pass
  # FOLD_AT. It does not fold before a space that another space or the end
  # follows, so no folded line is only white space.
  private def self.write_folded(io : IO, bytes : Bytes, column : Int32) : Nil
    size = bytes.size
    bytes.each_with_index do |byte, index|
      if byte == SPACE && index > 0 && index + 1 < size && bytes[index + 1] != SPACE
        stop = index + 1
        while stop < size && bytes[stop] != SPACE
          stop += 1
        end
        if column + (stop - index) > FOLD_AT
          io << "\r\n"
          column = 0
        end
      end
      io.write_byte(byte)
      column += 1
    end
  end

  # Writes RFC 2047 "B" encoded words, CRLF + space between them.
  # A word never splits a UTF-8 character. A UTF-8 character has at most
  # 3 continuation bytes, so the loop moves back at most 3 bytes.
  private def self.write_encoded(io : IO, bytes : Bytes) : Nil
    size = bytes.size
    start = 0
    while start < size
      stop = Math.min(start + WORD_BYTES, size)
      3.times do
        break unless stop < size && (bytes[stop] & 0xC0) == 0x80
        stop -= 1
      end
      io << "\r\n " if start > 0
      io << "=?UTF-8?B?"
      Base64.strict_encode(bytes[start, stop - start], io)
      io << "?="
      start = stop
    end
  end
end
