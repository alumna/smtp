require "./spec_helper"
require "wait_group"

private def mail(to : String | Array(String) = "user@example.com") : Alumna::Mail
  Alumna::Mail.new(from: "Alumna <noreply@example.com>", to: to, subject: "Welcome", text: "Hello")
end

private def mailer(
  server : ScriptedServer,
  *,
  tls : Alumna::SMTP::TLS = :none,
  username : String? = nil,
  password : String? = nil,
  read_timeout : Time::Span = 5.seconds,
) : Alumna::SMTP
  Alumna::SMTP.new(
    host: "127.0.0.1",
    port: server.port,
    tls: tls,
    username: username,
    password: password,
    helo_name: "client.example",
    tls_context: ScriptedServer.client_context,
    read_timeout: read_timeout,
  )
end

private def error_message(result : Alumna::MailError?) : String
  result.should be_a(Alumna::MailError)
  result.try(&.message) || ""
end

private SMTP_ENV = %w[SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS]

# Sets the SMTP variables for the block, then puts the old values back.
private def with_env(values : Hash(String, String), &)
  saved = SMTP_ENV.to_h { |name| {name, ENV[name]?} }
  SMTP_ENV.each { |name| ENV.delete(name) }
  values.each { |name, value| ENV[name] = value }
  yield
ensure
  saved.try &.each { |name, value| value ? (ENV[name] = value) : ENV.delete(name) }
end

private def argument_error(message : String, &)
  expect_raises(ArgumentError, message) { yield }
end

describe Alumna::SMTP do
  it "sends through the Mailer port" do
    server = ScriptedServer.new.start
    mailer(server).as(Alumna::Mailer).send(mail).should be_nil
    server.wait
    server.commands.should eq([
      "EHLO client.example",
      "MAIL FROM:<noreply@example.com>",
      "RCPT TO:<user@example.com>",
      "DATA",
      "QUIT",
    ])
    server.data.should contain("Subject: Welcome\r\n")
  end

  it "sends with STARTTLS and AUTH" do
    server = ScriptedServer.new.start
    mailer(server, tls: :starttls, username: "user", password: "secret").send(mail).should be_nil
    server.wait
    server.commands[0, 4].should eq(["EHLO client.example", "STARTTLS", "EHLO client.example", "AUTH PLAIN #{Base64.strict_encode("\0user\0secret")}"])
  end

  it "sends with implicit TLS" do
    server = ScriptedServer.new
    server.implicit_tls = true
    server.start
    mailer(server, tls: :implicit, username: "user", password: "secret").send(mail).should be_nil
    server.wait
    server.tls_flags.all?.should be_true
  end

  it "returns the session error" do
    server = ScriptedServer.new
    server.replies["RCPT"] = "550 5.1.1 no such user"
    server.start
    error_message(mailer(server).send(mail)).should eq("SMTP send failed (550) for user@example.com: 5.1.1 no such user")
    server.wait
  end

  it "refuses an unsupported address before it connects" do
    server = ScriptedServer.new
    server.close
    error_message(mailer(server).send(mail("josé@example.com"))).should eq("SMTP address is not supported: josé@example.com")
  end

  it "returns MailError when the connection is refused" do
    server = ScriptedServer.new
    server.close
    error_message(mailer(server).send(mail)).should eq("mail send failed")
  end

  it "returns MailError when the server does not answer in time" do
    listener = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(TCPSocket).new(1)
    spawn { accepted.send(listener.accept) }
    silent = Alumna::SMTP.new(host: "127.0.0.1", port: listener.local_address.port, tls: :none,
      helo_name: "client.example", read_timeout: 100.milliseconds)
    error_message(silent.send(mail)).should eq("mail send failed")
    accepted.receive.close
    listener.close
  end

  it "sends concurrent messages on separate connections" do
    servers = Array.new(4) { ScriptedServer.new.start }
    results = Array(Alumna::MailError?).new(4, Alumna::MailError.new("not sent"))
    WaitGroup.wait do |group|
      servers.each_with_index do |server, index|
        group.spawn { results[index] = mailer(server).send(mail("user#{index}@example.com")) }
      end
    end
    servers.each(&.wait)
    results.should eq([nil, nil, nil, nil])
    servers.each_with_index { |server, index| server.commands.should contain("RCPT TO:<user#{index}@example.com>") }
  end

  describe ".new" do
    it "uses the default port of each mode" do
      Alumna::SMTP.new(host: "smtp.example.com").port.should eq(587)
      Alumna::SMTP.new(host: "smtp.example.com", tls: :implicit).port.should eq(465)
      Alumna::SMTP.new(host: "smtp.example.com", tls: :none).port.should eq(25)
      Alumna::SMTP.new(host: "smtp.example.com", port: 2525).port.should eq(2525)
    end

    it "uses STARTTLS and the system host name by default" do
      smtp = Alumna::SMTP.new(host: "smtp.example.com")
      smtp.host.should eq("smtp.example.com")
      smtp.tls.should eq(Alumna::SMTP::TLS::Starttls)
      smtp.helo_name.should eq(System.hostname)
    end

    it "rejects an empty host" do
      argument_error("host must not be empty") { Alumna::SMTP.new(host: "") }
    end

    it "rejects a port out of range" do
      argument_error("port must be between 1 and 65535") { Alumna::SMTP.new(host: "h", port: 0) }
      argument_error("port must be between 1 and 65535") { Alumna::SMTP.new(host: "h", port: 65536) }
    end

    it "rejects a username without a password, and the reverse" do
      argument_error("username and password must be set together") { Alumna::SMTP.new(host: "h", username: "u") }
      argument_error("username and password must be set together") { Alumna::SMTP.new(host: "h", password: "p") }
    end

    it "rejects an empty username or password" do
      argument_error("username must not be empty") { Alumna::SMTP.new(host: "h", username: "", password: "p") }
      argument_error("password must not be empty") { Alumna::SMTP.new(host: "h", username: "u", password: "") }
    end

    it "rejects AUTH without TLS" do
      argument_error("AUTH needs TLS") { Alumna::SMTP.new(host: "h", tls: :none, username: "u", password: "p") }
    end

    it "rejects a bad helo_name" do
      argument_error("helo_name must not be empty") { Alumna::SMTP.new(host: "h", helo_name: "") }
      ["a b", "a\r\nRSET", "héllo"].each do |name|
        argument_error("helo_name must be printable ASCII with no space") { Alumna::SMTP.new(host: "h", helo_name: name) }
      end
    end

    it "rejects a timeout that is not positive" do
      argument_error("timeouts must be positive") { Alumna::SMTP.new(host: "h", connect_timeout: Time::Span.zero) }
      argument_error("timeouts must be positive") { Alumna::SMTP.new(host: "h", read_timeout: -1.seconds) }
      argument_error("timeouts must be positive") { Alumna::SMTP.new(host: "h", write_timeout: Time::Span.zero) }
    end
  end

  describe ".from_env" do
    it "reads every variable" do
      with_env({"SMTP_HOST" => "smtp.example.com", "SMTP_PORT" => "2525", "SMTP_USERNAME" => "u",
                "SMTP_PASSWORD" => "p", "SMTP_TLS" => "IMPLICIT"}) do
        smtp = Alumna::SMTP.from_env(helo_name: "client.example")
        smtp.host.should eq("smtp.example.com")
        smtp.port.should eq(2525)
        smtp.tls.should eq(Alumna::SMTP::TLS::Implicit)
        smtp.helo_name.should eq("client.example")
      end
    end

    it "uses the defaults when only SMTP_HOST is set" do
      with_env({"SMTP_HOST" => "smtp.example.com"}) do
        smtp = Alumna::SMTP.from_env
        smtp.port.should eq(587)
        smtp.tls.should eq(Alumna::SMTP::TLS::Starttls)
      end
    end

    it "sends with the variables" do
      server = ScriptedServer.new.start
      with_env({"SMTP_HOST" => "127.0.0.1", "SMTP_PORT" => server.port.to_s, "SMTP_TLS" => "none"}) do
        Alumna::SMTP.from_env(helo_name: "client.example").send(mail).should be_nil
      end
      server.wait
    end

    it "rejects a missing or empty SMTP_HOST" do
      with_env({} of String => String) { argument_error("SMTP_HOST must not be empty") { Alumna::SMTP.from_env } }
      with_env({"SMTP_HOST" => ""}) { argument_error("SMTP_HOST must not be empty") { Alumna::SMTP.from_env } }
    end

    it "rejects a bad SMTP_PORT" do
      with_env({"SMTP_HOST" => "h", "SMTP_PORT" => "abc"}) { argument_error("SMTP_PORT is invalid") { Alumna::SMTP.from_env } }
      with_env({"SMTP_HOST" => "h", "SMTP_PORT" => "70000"}) { argument_error("port must be between 1 and 65535") { Alumna::SMTP.from_env } }
    end

    it "rejects a bad SMTP_TLS" do
      with_env({"SMTP_HOST" => "h", "SMTP_TLS" => "ssl"}) do
        argument_error("SMTP_TLS must be starttls, implicit, or none") { Alumna::SMTP.from_env }
      end
    end

    it "rejects a variable that is set but empty" do
      {"SMTP_PORT", "SMTP_USERNAME", "SMTP_PASSWORD", "SMTP_TLS"}.each do |name|
        with_env({"SMTP_HOST" => "h", name => ""}) { argument_error("#{name} must not be empty") { Alumna::SMTP.from_env } }
      end
    end
  end
end

describe "live SMTP" do
  it "sends when SMTP_LIVE=1" do
    unless ENV["SMTP_LIVE"]? == "1"
      pending!("set SMTP_LIVE=1, SMTP_LIVE_FROM, SMTP_LIVE_TO, and the SMTP_* variables")
    end
    from = ENV["SMTP_LIVE_FROM"]? || ""
    to = ENV["SMTP_LIVE_TO"]? || ""
    live = Alumna::Mail.new(from: from, to: to, subject: "Alumna SMTP live spec", text: "Sent by the alumna-smtp live spec.",
      html: "<p>Sent by the <b>alumna-smtp</b> live spec.</p>")
    Alumna::SMTP.from_env.send(live).should be_nil
  end
end
