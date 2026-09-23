# One SMTP dialog on one connection (RFC 5321, RFC 3207 STARTTLS, RFC 4954 AUTH).
#
# greeting (220), EHLO (250), [STARTTLS (220), TLS, EHLO (250)], [AUTH (235)],
# MAIL FROM (250), RCPT TO (250/251) for each address, DATA (354),
# message + "." (250), QUIT.
#
# The session owns the IO. It wraps it in TLS when the mode asks for it,
# and it closes it at the end. Each command is one write and one flush.
#
# Result: nil when the server accepted the message (250 after the data).
# A reply that is not the expected code: MailError "SMTP send failed (code): text".
# A refused recipient: RSET, QUIT, MailError with the address.
# Network, TLS, and timeout errors: MailError "mail send failed".
# A malformed reply: MailError "SMTP server sent an invalid reply".
# The username and the password are replaced with [redacted] in error text.
#
# EHLO only (no HELO fallback). The message needs no dot-stuffing:
# Message.write never starts a line with ".".
class Alumna::SMTP::Session
  # A reply line longer than this is invalid. RFC 5321 allows 512 with CRLF.
  MAX_LINE = 1024
  # A multi-line reply with more lines is invalid. It stops an endless reply.
  MAX_LINES = 100

  # A reply that does not follow RFC 5321 section 4.2.
  private class InvalidReply < Exception
  end

  @io : IO
  @host : String
  @tls : TLS
  @tls_context : OpenSSL::SSL::Context::Client
  @helo_name : String
  @username : String?
  @password : String?
  # Last reply: its code and its last line (the text starts at byte 4).
  @code = 0
  @line = ""
  # EHLO extensions. Reset on each EHLO.
  @starttls = false
  @auth_plain = false
  @auth_login = false

  # Checks the envelope before a connection opens. The address of from and of
  # each recipient must be printable ASCII with no space, "<", or ">".
  # A non-ASCII address needs SMTPUTF8, which this shard does not support.
  def self.check(mail : Mail) : MailError?
    if error = unsupported_address(mail.from)
      return error
    end
    mail.to.each do |value|
      if error = unsupported_address(value)
        return error
      end
    end
    nil
  end

  # `host` is the server name for TLS (SNI and certificate check).
  def initialize(
    @io : IO,
    *,
    @host : String,
    @tls : TLS,
    @tls_context : OpenSSL::SSL::Context::Client,
    @helo_name : String,
    @username : String? = nil,
    @password : String? = nil,
  )
  end

  # Runs the full dialog for one mail. Call it once. The IO is closed after it.
  def run(mail : Mail) : MailError?
    start_tls if @tls.implicit?
    return failure unless read_reply == 220
    return failure unless ehlo

    if @tls.starttls?
      return quit_with(MailError.new("SMTP server does not offer STARTTLS")) unless @starttls
      return failure unless command("STARTTLS") == 220
      start_tls
      return failure unless ehlo
    end

    if username = @username
      if error = authenticate(username, @password || "")
        return error
      end
    end

    return failure unless mail_from(mail.from) == 250
    mail.to.each do |recipient|
      code = rcpt_to(recipient)
      next if code == 250 || code == 251
      error = MailError.new(redact("SMTP send failed (#{code}) for #{recipient}: #{reply_text}"))
      write_line("RSET")
      read_reply
      return quit_with(error)
    end

    return failure unless command("DATA") == 354
    Message.write(@io, mail)
    @io << ".\r\n"
    @io.flush
    return failure unless read_reply == 250

    quit
    nil
  rescue InvalidReply
    MailError.new("SMTP server sent an invalid reply")
  rescue IO::Error | OpenSSL::Error
    MailError.new("mail send failed")
  ensure
    close
  end

  private def self.unsupported_address(value : String) : MailError?
    address = Header.address(value)
    supported = address.all? { |byte| byte >= 33_u8 && byte <= 126_u8 && byte != 60_u8 && byte != 62_u8 }
    return nil if supported
    MailError.new("SMTP address is not supported: #{value}")
  end

  # Wraps the IO in TLS. The certificate must match `host` (hostname check).
  private def start_tls : Nil
    @io = OpenSSL::SSL::Socket::Client.new(@io, @tls_context, sync_close: true, hostname: @host)
  end

  # EHLO and its extensions. True on 250.
  private def ehlo : Bool
    @starttls = false
    @auth_plain = false
    @auth_login = false
    @io << "EHLO " << @helo_name << "\r\n"
    @io.flush
    read_reply(extensions: true) == 250
  end

  # AUTH PLAIN when offered, else AUTH LOGIN. nil on 235.
  private def authenticate(username : String, password : String) : MailError?
    if @auth_plain
      @io << "AUTH PLAIN "
      Base64.strict_encode("\0#{username}\0#{password}", @io)
      @io << "\r\n"
      @io.flush
      return read_reply == 235 ? nil : failure
    end
    return quit_with(MailError.new("SMTP server offers no supported AUTH mechanism")) unless @auth_login

    return failure unless command("AUTH LOGIN") == 334
    return failure unless secret_line(username) == 334
    secret_line(password) == 235 ? nil : failure
  end

  # One base64 line for AUTH LOGIN.
  private def secret_line(value : String) : Int32
    Base64.strict_encode(value, @io)
    @io << "\r\n"
    @io.flush
    read_reply
  end

  private def mail_from(value : String) : Int32
    @io << "MAIL FROM:<"
    @io.write(Header.address(value))
    @io << ">\r\n"
    @io.flush
    read_reply
  end

  private def rcpt_to(value : String) : Int32
    @io << "RCPT TO:<"
    @io.write(Header.address(value))
    @io << ">\r\n"
    @io.flush
    read_reply
  end

  private def command(line : String) : Int32
    write_line(line)
    read_reply
  end

  private def write_line(line : String) : Nil
    @io << line << "\r\n"
    @io.flush
  end

  # Reads one reply (one or more lines) and returns its code.
  # "250-text" means more lines follow. "250 text" or "250" is the last line.
  private def read_reply(extensions : Bool = false) : Int32
    count = 0
    loop do
      line = @io.gets(MAX_LINE, chomp: true)
      raise IO::EOFError.new unless line
      count += 1
      raise InvalidReply.new if count > MAX_LINES
      code = reply_code(line)
      last = line.bytesize == 3 || line.byte_at(3) == 32_u8
      raise InvalidReply.new unless last || line.byte_at(3) == 45_u8
      # The first EHLO line is the server name. Extensions follow.
      read_extension(line) if extensions && count > 1
      if last
        @code = code
        @line = line
        return code
      end
    end
  end

  # The three digits at the start of a reply line.
  private def reply_code(line : String) : Int32
    raise InvalidReply.new if line.bytesize < 3
    code = 0
    3.times do |index|
      byte = line.byte_at(index)
      raise InvalidReply.new unless byte >= 48_u8 && byte <= 57_u8
      code = code * 10 + (byte - 48_u8)
    end
    code
  end

  # Reads "STARTTLS" and "AUTH PLAIN LOGIN" (also the old "AUTH=PLAIN LOGIN").
  # Keywords are not case sensitive.
  private def read_extension(line : String) : Nil
    return if line.bytesize < 5
    keyword = line.byte_slice(4)
    if keyword.compare("STARTTLS", case_insensitive: true) == 0
      @starttls = true
      return
    end
    return unless keyword.size > 5 && keyword[0, 4].compare("AUTH", case_insensitive: true) == 0
    return unless keyword[4] == ' ' || keyword[4] == '='
    keyword[5..].split(' ', remove_empty: true).each do |mechanism|
      @auth_plain = true if mechanism.compare("PLAIN", case_insensitive: true) == 0
      @auth_login = true if mechanism.compare("LOGIN", case_insensitive: true) == 0
    end
  end

  # The text of the last reply line, without the code.
  private def reply_text : String
    @line.bytesize > 4 ? @line.byte_slice(4) : ""
  end

  # MailError for the last reply, after QUIT.
  private def failure : MailError
    quit_with(MailError.new(redact("SMTP send failed (#{@code}): #{reply_text}")))
  end

  private def quit_with(error : MailError) : MailError
    quit
    error
  end

  # QUIT is polite. A failure here does not change the result.
  private def quit : Nil
    write_line("QUIT")
    read_reply
  rescue IO::Error | OpenSSL::Error | InvalidReply
  end

  private def close : Nil
    @io.close
  rescue IO::Error | OpenSSL::Error
  end

  # Removes the username and the password, also in the base64 forms that AUTH
  # sends, in case the server echoes a command. Runs only on the error path.
  # The longest secret goes first, so a short one cannot cut a long one.
  private def redact(text : String) : String
    username = @username
    return text unless username
    password = @password || ""
    secrets = [Base64.strict_encode("\0#{username}\0#{password}"), Base64.strict_encode(username),
               Base64.strict_encode(password), username, password]
    secrets.sort_by! { |secret| -secret.bytesize }
    secrets.each do |secret|
      text = text.gsub(secret, "[redacted]") unless secret.empty?
    end
    text
  end
end
