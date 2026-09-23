# Writes one Mail as an RFC 5322 / MIME message for the SMTP DATA phase.
# The message streams to the IO. There is no String for the full message.
#
# Text only (html nil or empty): one text/plain part.
# Text + html: multipart/alternative, text first, html last (RFC 2046).
# Bodies are UTF-8 quoted-printable. Every line ends in CRLF.
#
# No line starts with ".": headers start with a name, folded lines with a
# space, boundaries with "--", and QuotedPrintable writes a first "." as =2E.
# The session writes "." CRLF after this output and needs no dot-stuffing.
#
# The output is ASCII, except a bare address with non-ASCII bytes.
# The session must refuse that address (no SMTPUTF8 support).
module Alumna::SMTP::Message
  # Used when the from-address has no "@" domain.
  FALLBACK_DOMAIN = "localhost"

  TEXT_HEADERS = "Content-Type: text/plain; charset=UTF-8\r\n" \
                 "Content-Transfer-Encoding: quoted-printable\r\n"
  HTML_HEADERS = "Content-Type: text/html; charset=UTF-8\r\n" \
                 "Content-Transfer-Encoding: quoted-printable\r\n"

  # `time` goes into Date. `token` is random hex for Message-ID and the boundary.
  # Specs pass both, so the bytes are the same on each run.
  #
  # The boundary starts with "=_". Quoted-printable always writes "=" as "=3D"
  # (a soft break is "=" + CRLF), so a body line cannot contain the boundary.
  def self.write(io : IO, mail : Mail, *, time : Time = Time.utc, token : String = Random::Secure.hex(16)) : Nil
    io << "Date: "
    Time::Format::RFC_2822.format(time.to_utc, io)
    io << "\r\n"
    Header.write_address(io, "From", mail.from)
    Header.write_addresses(io, "To", mail.to)
    if reply = mail.reply_to
      Header.write_address(io, "Reply-To", reply)
    end
    Header.write_text(io, "Subject", mail.subject)
    write_message_id(io, mail.from, token)
    io << "MIME-Version: 1.0\r\n"

    html = mail.html
    if html.nil? || html.empty?
      io << TEXT_HEADERS << "\r\n"
      QuotedPrintable.write(io, mail.text)
      return
    end

    io << "Content-Type: multipart/alternative;\r\n boundary=\"=_" << token << "\"\r\n\r\n"
    io << "--=_" << token << "\r\n" << TEXT_HEADERS << "\r\n"
    QuotedPrintable.write(io, mail.text)
    io << "--=_" << token << "\r\n" << HTML_HEADERS << "\r\n"
    QuotedPrintable.write(io, html)
    io << "--=_" << token << "--\r\n"
  end

  private def self.write_message_id(io : IO, from : String, token : String) : Nil
    io << "Message-ID: <" << token << '@'
    domain = Header.domain(from)
    if domain.empty?
      io << FALLBACK_DOMAIN
    else
      io.write(domain)
    end
    io << ">\r\n"
  end
end
