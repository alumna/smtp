require "./spec_helper"

private def mail(to : String | Array(String) = "user@example.com", from : String = "Alumna <noreply@example.com>") : Alumna::Mail
  Alumna::Mail.new(from: from, to: to, subject: "Welcome", text: "Hello", html: "<p>Hello</p>")
end

private def run_session(
  server : ScriptedServer,
  message : Alumna::Mail = mail,
  *,
  tls : Alumna::SMTP::TLS = :none,
  username : String? = nil,
  password : String? = nil,
  context : OpenSSL::SSL::Context::Client = ScriptedServer.client_context,
) : Alumna::MailError?
  server.start
  socket = TCPSocket.new("127.0.0.1", server.port)
  socket.sync = false
  socket.tcp_nodelay = true
  # A bug must fail the spec, not hang CI.
  socket.read_timeout = 5.seconds
  session = Alumna::SMTP::Session.new(
    socket,
    host: "127.0.0.1",
    tls: tls,
    tls_context: context,
    helo_name: "client.example",
    username: username,
    password: password,
  )
  result = session.run(message)
  server.wait
  result
end

private def error_message(result : Alumna::MailError?) : String
  result.should be_a(Alumna::MailError)
  result.try(&.message) || ""
end

describe Alumna::SMTP::Session do
  it "sends without TLS and without AUTH" do
    server = ScriptedServer.new
    run_session(server).should be_nil
    server.commands.should eq([
      "EHLO client.example",
      "MAIL FROM:<noreply@example.com>",
      "RCPT TO:<user@example.com>",
      "DATA",
      "QUIT",
    ])
    server.data.should contain("From: Alumna <noreply@example.com>\r\n")
    server.data.should contain("Subject: Welcome\r\n")
    server.data.should contain("Content-Type: text/html; charset=UTF-8\r\n")
    server.data.should end_with("--\r\n")
  end

  it "sends one RCPT TO for each recipient" do
    server = ScriptedServer.new
    run_session(server, mail(["a@example.com", "Bee <b@example.com>"])).should be_nil
    server.commands.should contain("RCPT TO:<a@example.com>")
    server.commands.should contain("RCPT TO:<b@example.com>")
  end

  it "upgrades with STARTTLS, sends EHLO again, and uses AUTH PLAIN" do
    server = ScriptedServer.new
    run_session(server, tls: :starttls, username: "user", password: "secret").should be_nil
    plain = Base64.strict_encode("\0user\0secret")
    server.commands.should eq([
      "EHLO client.example",
      "STARTTLS",
      "EHLO client.example",
      "AUTH PLAIN #{plain}",
      "MAIL FROM:<noreply@example.com>",
      "RCPT TO:<user@example.com>",
      "DATA",
      "QUIT",
    ])
    server.tls_flags.should eq([false, false, true, true, true, true, true, true])
  end

  it "uses AUTH LOGIN when PLAIN is not offered" do
    server = ScriptedServer.new
    server.auth_line = "AUTH LOGIN"
    run_session(server, tls: :starttls, username: "user", password: "secret").should be_nil
    server.commands[3, 3].should eq(["AUTH LOGIN", Base64.strict_encode("user"), Base64.strict_encode("secret")])
  end

  it "reads the old AUTH= form and lower-case keywords" do
    server = ScriptedServer.new
    server.auth_line = "auth=login"
    server.extra_extensions = ["starttls", "SIZE"]
    server.offer_starttls = false
    run_session(server, tls: :starttls, username: "user", password: "secret").should be_nil
    server.commands.should contain("STARTTLS")
    server.commands.should contain("AUTH LOGIN")
  end

  it "ignores AUTH with no mechanisms and other AUTH-like keywords" do
    server = ScriptedServer.new
    server.auth_line = "AUTH"
    server.extra_extensions = ["AUTHX PLAIN", "AUTH=", "AUTH  CRAM-MD5  LOGIN "]
    run_session(server, tls: :starttls, username: "user", password: "secret").should be_nil
    server.commands.should contain("AUTH LOGIN")
  end

  it "sends an empty password with AUTH LOGIN when none is set" do
    server = ScriptedServer.new
    server.auth_line = "AUTH LOGIN"
    run_session(server, tls: :starttls, username: "user").should be_nil
    server.commands[5].should eq("")
  end

  it "uses implicit TLS from the first byte" do
    server = ScriptedServer.new
    server.implicit_tls = true
    run_session(server, tls: :implicit, username: "user", password: "secret").should be_nil
    server.commands.first.should eq("EHLO client.example")
    server.commands.should_not contain("STARTTLS")
    server.tls_flags.all?.should be_true
  end

  it "fails when STARTTLS is not offered" do
    server = ScriptedServer.new
    server.offer_starttls = false
    error_message(run_session(server, tls: :starttls)).should eq("SMTP server does not offer STARTTLS")
    server.commands.should eq(["EHLO client.example", "QUIT"])
  end

  it "fails when STARTTLS is refused" do
    server = ScriptedServer.new
    server.replies["STARTTLS"] = "454 4.7.0 TLS not available"
    error_message(run_session(server, tls: :starttls)).should eq("SMTP send failed (454): 4.7.0 TLS not available")
  end

  it "fails when the server does not start TLS after STARTTLS" do
    server = ScriptedServer.new
    # Plain text where the TLS handshake must be. The handshake fails at once.
    server.replies["STARTTLS"] = "220 go\r\nthis is not TLS"
    error_message(run_session(server, tls: :starttls)).should eq("mail send failed")
  end

  it "fails when the EHLO after STARTTLS is refused" do
    server = ScriptedServer.new
    server.tls_ehlo_reply = "554 5.7.0 no"
    error_message(run_session(server, tls: :starttls)).should eq("SMTP send failed (554): 5.7.0 no")
    server.commands.should eq(["EHLO client.example", "STARTTLS", "EHLO client.example", "QUIT"])
  end

  it "fails when the certificate is not trusted" do
    server = ScriptedServer.new
    server.implicit_tls = true
    error_message(run_session(server, tls: :implicit, context: OpenSSL::SSL::Context::Client.new)).should eq("mail send failed")
  end

  it "fails when no AUTH mechanism is supported" do
    server = ScriptedServer.new
    server.auth_line = "AUTH CRAM-MD5"
    error_message(run_session(server, tls: :starttls, username: "user", password: "secret"))
      .should eq("SMTP server offers no supported AUTH mechanism")
    server.commands.last.should eq("QUIT")
  end

  it "redacts the credentials when AUTH PLAIN is refused" do
    server = ScriptedServer.new
    plain = Base64.strict_encode("\0user@example.com\0pa55word")
    server.replies["AUTH"] = "535 5.7.8 bad #{plain} for user@example.com / pa55word"
    message = error_message(run_session(server, tls: :starttls, username: "user@example.com", password: "pa55word"))
    message.should eq("SMTP send failed (535): 5.7.8 bad [redacted] for [redacted] / [redacted]")
  end

  it "fails when AUTH LOGIN is refused at each step" do
    {"AUTH", "LOGIN_USER", "LOGIN_PASSWORD", "LOGIN_DONE"}.each do |step|
      server = ScriptedServer.new
      server.auth_line = "AUTH LOGIN"
      if step == "AUTH"
        server.replies["AUTH LOGIN"] = "504 5.5.4 no"
      else
        server.replies[step] = "535 5.7.8 no"
      end
      error_message(run_session(server, tls: :starttls, username: "user", password: "secret")).should start_with("SMTP send failed (5")
    end
  end

  it "fails on a greeting that is not 220" do
    server = ScriptedServer.new
    server.greeting = "554 5.3.2 go away"
    error_message(run_session(server)).should eq("SMTP send failed (554): 5.3.2 go away")
  end

  it "accepts a multi-line greeting and a reply with no text" do
    server = ScriptedServer.new
    server.greeting = "220-first\r\n220-second\r\n220"
    server.replies["RSET"] = "250"
    server.replies["MAIL"] = "250"
    run_session(server).should be_nil
  end

  it "fails when EHLO is refused (no HELO fallback)" do
    server = ScriptedServer.new
    server.replies["EHLO"] = "502 5.5.1 not implemented"
    error_message(run_session(server)).should eq("SMTP send failed (502): 5.5.1 not implemented")
    server.commands.should eq(["EHLO client.example", "QUIT"])
  end

  it "fails when MAIL FROM is refused" do
    server = ScriptedServer.new
    server.replies["MAIL"] = "553 5.1.8 sender refused"
    error_message(run_session(server)).should eq("SMTP send failed (553): 5.1.8 sender refused")
  end

  it "fails the whole send when one recipient is refused" do
    server = ScriptedServer.new
    server.replies["RCPT TO:<b@example.com>"] = "550 5.1.1 no such user"
    error_message(run_session(server, mail(["a@example.com", "Bee <b@example.com>", "c@example.com"])))
      .should eq("SMTP send failed (550) for Bee <b@example.com>: 5.1.1 no such user")
    server.commands.should eq([
      "EHLO client.example",
      "MAIL FROM:<noreply@example.com>",
      "RCPT TO:<a@example.com>",
      "RCPT TO:<b@example.com>",
      "RSET",
      "QUIT",
    ])
  end

  it "accepts 251 for a recipient" do
    server = ScriptedServer.new
    server.replies["RCPT"] = "251 2.1.5 will forward"
    run_session(server).should be_nil
  end

  it "fails when DATA is refused" do
    server = ScriptedServer.new
    server.replies["DATA"] = "554 5.5.1 no valid recipients"
    error_message(run_session(server)).should eq("SMTP send failed (554): 5.5.1 no valid recipients")
  end

  it "fails when the message is refused after the data" do
    server = ScriptedServer.new
    server.data_reply = "552 5.3.4 message too big"
    error_message(run_session(server)).should eq("SMTP send failed (552): 5.3.4 message too big")
    server.commands.last.should eq("QUIT")
  end

  it "returns nil when QUIT fails after the message is accepted" do
    server = ScriptedServer.new
    server.close_on = "QUIT"
    run_session(server).should be_nil
  end

  it "returns nil when the QUIT reply is invalid" do
    server = ScriptedServer.new
    server.replies["QUIT"] = "bye"
    run_session(server).should be_nil
  end

  it "fails when the connection closes before the greeting" do
    server = ScriptedServer.new
    server.greeting = nil
    error_message(run_session(server)).should eq("mail send failed")
  end

  it "fails when the connection closes in the dialog" do
    server = ScriptedServer.new
    server.close_on = "RCPT"
    error_message(run_session(server)).should eq("mail send failed")
  end

  it "fails on an invalid reply" do
    ["hello", "22", "2x0 ok", "250_ok", "220-a\r\n220-b\r\n#{"220-more\r\n" * 99}220 end"].each do |greeting|
      server = ScriptedServer.new
      server.greeting = greeting
      error_message(run_session(server)).should eq("SMTP server sent an invalid reply")
    end
  end

  it "fails on a reply line that is too long" do
    server = ScriptedServer.new
    server.greeting = "220 #{"x" * 1100}"
    error_message(run_session(server)).should eq("SMTP server sent an invalid reply")
  end

  it "does not redact when there is no username" do
    server = ScriptedServer.new
    server.replies["MAIL"] = "553 AAA= refused"
    error_message(run_session(server)).should eq("SMTP send failed (553): AAA= refused")
  end

  describe ".check" do
    it "accepts ASCII addresses and non-ASCII display names" do
      Alumna::SMTP::Session.check(mail(["José <jose@example.com>", "b@example.com"])).should be_nil
    end

    it "refuses a non-ASCII from address" do
      error_message(Alumna::SMTP::Session.check(mail(from: "josé@example.com")))
        .should eq("SMTP address is not supported: josé@example.com")
    end

    it "refuses a recipient with a space, < or >" do
      ["a b@example.com", "a<b@example.com", "a>b@example.com"].each do |address|
        error_message(Alumna::SMTP::Session.check(mail(["ok@example.com", address])))
          .should eq("SMTP address is not supported: #{address}")
      end
    end
  end
end
