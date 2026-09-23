require "socket"
require "openssl"

# A small SMTP server for specs. One connection per instance.
# Model: devmail (accept, spawn, dispatch on the first word), with STARTTLS,
# implicit TLS, AUTH PLAIN/LOGIN, and reply overrides added.
#
# It binds 127.0.0.1 port 0, so parallel runs do not collide.
# It records each command line (without CRLF) and the DATA bytes (with CRLF).
class ScriptedServer
  FIXTURES = "#{__DIR__}/../fixtures"

  getter port : Int32
  getter commands = [] of String
  getter data = ""
  # True when the command came over TLS. Same index as `commands`.
  getter tls_flags = [] of Bool

  # Raw greeting. nil closes the connection before a greeting.
  property greeting : String? = "220 test.example ESMTP"
  property offer_starttls = true
  property auth_line : String? = "AUTH PLAIN LOGIN"
  property extra_extensions = ["8BITMIME", "SIZE 1000000"]
  property implicit_tls = false
  # Reply for a command, by the full line or by the first word (upper case).
  # The full line is checked first. The value is raw ("\r\n" for more lines).
  property replies = {} of String => String
  # Reply after the "." of the DATA phase.
  property data_reply = "250 2.0.0 queued"
  # Close the connection when this command arrives (full line or first word).
  property close_on : String? = nil
  # Reply to EHLO over TLS, instead of the extension list.
  property tls_ehlo_reply : String? = nil

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @done = Channel(Nil).new(1)
    @tls = false
  end

  def self.server_context : OpenSSL::SSL::Context::Server
    context = OpenSSL::SSL::Context::Server.new
    context.certificate_chain = "#{FIXTURES}/test_cert.pem"
    context.private_key = "#{FIXTURES}/test_key.pem"
    context
  end

  # A client context that trusts only the test certificate.
  def self.client_context : OpenSSL::SSL::Context::Client
    context = OpenSSL::SSL::Context::Client.new
    context.ca_certificates = "#{FIXTURES}/test_cert.pem"
    context
  end

  # Accepts one connection in a new fiber.
  def start : self
    spawn do
      client = @server.accept
      begin
        serve(client)
      rescue IO::Error | OpenSSL::Error
        # The client closed the connection or refused the certificate.
      ensure
        client.close rescue nil
        @server.close
        @done.send(nil)
      end
    end
    self
  end

  # Waits until the connection ends. Fails the spec after 5 seconds.
  def wait : Nil
    select
    when @done.receive
    when timeout(5.seconds)
      raise "scripted SMTP server did not finish"
    end
  end

  # Closes the listener without a connection (for "connection refused").
  def close : Nil
    @server.close
  end

  private def serve(client : TCPSocket) : Nil
    # One write per reply. With sync = true, "text" and CRLF are two small
    # writes, and Nagle + delayed ACK add about 200 ms to each reply.
    client.sync = false
    client.tcp_nodelay = true
    io = client.as(IO)
    if @implicit_tls
      io = OpenSSL::SSL::Socket::Server.new(client, ScriptedServer.server_context, sync_close: true)
      @tls = true
    end
    greeting = @greeting
    return unless greeting
    say(io, greeting)

    while line = io.gets(chomp: true)
      @commands << line
      @tls_flags << @tls
      verb = line.split(' ', 2).first.upcase
      return if @close_on == line || @close_on == verb
      if reply = @replies[line]? || @replies[verb]?
        say(io, reply)
        return if verb == "QUIT"
        next
      end
      case verb
      when "EHLO"
        tls_reply = @tls_ehlo_reply
        say(io, @tls && tls_reply ? tls_reply : ehlo_reply)
      when "STARTTLS"
        say(io, "220 2.0.0 ready")
        io = OpenSSL::SSL::Socket::Server.new(io, ScriptedServer.server_context, sync_close: true)
        @tls = true
      when "AUTH"
        auth(io, line)
      when "MAIL", "RCPT", "RSET", "NOOP"
        say(io, "250 2.1.0 ok")
      when "DATA"
        say(io, "354 end with .")
        read_data(io)
        say(io, @data_reply)
      when "QUIT"
        say(io, "221 2.0.0 bye")
        return
      else
        say(io, "500 5.5.1 unknown")
      end
    end
  end

  private def ehlo_reply : String
    lines = ["test.example"]
    lines << "STARTTLS" if @offer_starttls && !@tls
    if auth = @auth_line
      lines << auth
    end
    lines.concat(@extra_extensions)
    String.build do |io|
      lines.each_with_index do |text, index|
        io << "\r\n" if index > 0
        io << "250" << (index == lines.size - 1 ? ' ' : '-') << text
      end
    end
  end

  private def auth(io : IO, line : String) : Nil
    if line.upcase.starts_with?("AUTH PLAIN ")
      say(io, "235 2.7.0 accepted")
    elsif line.upcase == "AUTH LOGIN"
      say(io, @replies["LOGIN_USER"]? || "334 VXNlcm5hbWU6")
      user = io.gets(chomp: true)
      return unless user
      @commands << user
      @tls_flags << @tls
      say(io, @replies["LOGIN_PASSWORD"]? || "334 UGFzc3dvcmQ6")
      password = io.gets(chomp: true)
      return unless password
      @commands << password
      @tls_flags << @tls
      say(io, @replies["LOGIN_DONE"]? || "235 2.7.0 accepted")
    else
      say(io, "504 5.5.4 unknown mechanism")
    end
  end

  private def read_data(io : IO) : Nil
    buffer = IO::Memory.new
    while line = io.gets(chomp: false)
      break if line == ".\r\n"
      buffer << line
    end
    @data = buffer.to_s
  end

  private def say(io : IO, text : String) : Nil
    io << text << "\r\n"
    io.flush
  end
end
