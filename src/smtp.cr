require "base64"
require "openssl"
require "random/secure"
require "socket"
require "system"

module Alumna
  # Opened here so the nested types (TLS, QuotedPrintable, Header, Message,
  # Session) can load. The methods are in the class body below.
  class SMTP < Mailer
    # How the connection is encrypted.
    # Starttls: plain TCP, then STARTTLS before AUTH and MAIL (default port 587).
    #           A server that does not offer STARTTLS fails the send. No downgrade.
    # Implicit: TLS from the first byte (default port 465).
    # None:     no TLS (default port 25). Only for a local or trusted network. No AUTH.
    enum TLS
      Starttls
      Implicit
      None
    end
  end
end

require "./smtp/quoted_printable"
require "./smtp/header"
require "./smtp/message"
require "./smtp/session"

module Alumna
  # SMTP mailer. One method: send. This is not a Redis-style holder.
  #
  # Each send opens one new connection, runs one dialog, and closes it.
  # There is no shared connection state, so concurrent sends are safe.
  #
  # Success returns nil. A server refusal, a network error, a TLS error,
  # or a timeout returns MailError. Config mistakes raise ArgumentError.
  #
  # Do not log the password. MailError text has the username and the
  # password removed.
  class SMTP < Mailer
    DEFAULT_CONNECT_TIMEOUT = 10.seconds
    DEFAULT_READ_TIMEOUT    = 30.seconds
    DEFAULT_WRITE_TIMEOUT   = 30.seconds

    getter host : String
    getter port : Int32
    getter tls : TLS
    getter helo_name : String

    @username : String?
    @password : String?
    @tls_context : OpenSSL::SSL::Context::Client
    @connect_timeout : Time::Span
    @read_timeout : Time::Span
    @write_timeout : Time::Span

    # Reads SMTP_HOST, and the optional SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD,
    # and SMTP_TLS (starttls, implicit, or none; not case sensitive).
    # A variable that is set must not be empty.
    def self.from_env(
      *,
      helo_name : String = System.hostname,
      tls_context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
    ) : self
      host = ENV["SMTP_HOST"]?
      raise ArgumentError.new("SMTP_HOST must not be empty") if host.nil? || host.empty?

      port = nil
      if raw_port = env_value("SMTP_PORT")
        port = raw_port.to_i?
        raise ArgumentError.new("SMTP_PORT is invalid") unless port
      end

      tls = TLS::Starttls
      if raw_tls = env_value("SMTP_TLS")
        parsed = TLS.parse?(raw_tls)
        raise ArgumentError.new("SMTP_TLS must be starttls, implicit, or none") unless parsed
        tls = parsed
      end

      new(
        host: host,
        port: port,
        tls: tls,
        username: env_value("SMTP_USERNAME"),
        password: env_value("SMTP_PASSWORD"),
        helo_name: helo_name,
        tls_context: tls_context,
      )
    end

    # `port` nil means the default port of the mode (587, 465, or 25).
    # `tls_context` checks the server certificate. The default uses the system
    # CAs. Pass another context for a private CA or a client certificate.
    def initialize(
      *,
      host : String,
      port : Int32? = nil,
      tls : TLS = :starttls,
      username : String? = nil,
      password : String? = nil,
      helo_name : String = System.hostname,
      tls_context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      connect_timeout : Time::Span = DEFAULT_CONNECT_TIMEOUT,
      read_timeout : Time::Span = DEFAULT_READ_TIMEOUT,
      write_timeout : Time::Span = DEFAULT_WRITE_TIMEOUT,
    )
      raise ArgumentError.new("host must not be empty") if host.empty?
      port ||= default_port(tls)
      raise ArgumentError.new("port must be between 1 and 65535") unless port >= 1 && port <= 65535
      check_credentials(tls, username, password)
      # helo_name goes into the EHLO command. A space or a line break there
      # would change the command.
      raise ArgumentError.new("helo_name must not be empty") if helo_name.empty?
      unless helo_name.each_byte.all? { |byte| byte >= 33_u8 && byte <= 126_u8 }
        raise ArgumentError.new("helo_name must be printable ASCII with no space")
      end
      {connect_timeout, read_timeout, write_timeout}.each do |timeout|
        raise ArgumentError.new("timeouts must be positive") unless timeout > Time::Span.zero
      end

      @host = host
      @port = port
      @tls = tls
      @username = username
      @password = password
      @helo_name = helo_name
      @tls_context = tls_context
      @connect_timeout = connect_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
    end

    def send(mail : Mail) : Nil | MailError
      # Refuse an address this shard cannot send before a connection opens.
      if error = Session.check(mail)
        return error
      end
      socket = TCPSocket.new(@host, @port, dns_timeout: @connect_timeout, connect_timeout: @connect_timeout)
      # One write per command, and no Nagle delay (learnings/alumna-smtp.md).
      socket.sync = false
      socket.tcp_nodelay = true
      socket.read_timeout = @read_timeout
      socket.write_timeout = @write_timeout
      Session.new(
        socket,
        host: @host,
        tls: @tls,
        tls_context: @tls_context,
        helo_name: @helo_name,
        username: @username,
        password: @password,
      ).run(mail)
    rescue IO::Error
      # DNS failure, connection refused, or connect timeout. Socket::Error is an IO::Error.
      MailError.new("mail send failed")
    end

    # nil when the variable is not set. ArgumentError when it is set but empty.
    private def self.env_value(name : String) : String?
      value = ENV[name]?
      raise ArgumentError.new("#{name} must not be empty") if value && value.empty?
      value
    end

    private def default_port(tls : TLS) : Int32
      case tls
      in .starttls? then 587
      in .implicit? then 465
      in .none?     then 25
      end
    end

    # Username and password come together. AUTH needs TLS.
    private def check_credentials(tls : TLS, username : String?, password : String?) : Nil
      return if username.nil? && password.nil?
      raise ArgumentError.new("username and password must be set together") if username.nil? || password.nil?
      raise ArgumentError.new("username must not be empty") if username.empty?
      raise ArgumentError.new("password must not be empty") if password.empty?
      raise ArgumentError.new("AUTH needs TLS: use tls: :starttls or :implicit") if tls.none?
    end
  end
end
