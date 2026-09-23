require "./spec_helper"

private TIME  = Time.utc(2026, 9, 23, 19, 45, 0)
private TOKEN = "0123456789abcdef0123456789abcdef"

private def render(mail : Alumna::Mail) : String
  String.build { |io| Alumna::SMTP::Message.write(io, mail, time: TIME, token: TOKEN) }
end

private def mail(
  *,
  from : String = "Alumna <noreply@example.com>",
  to : String | Array(String) = "user@example.com",
  subject : String = "Welcome",
  text : String = "Hello",
  html : String? = nil,
  reply_to : String? = nil,
) : Alumna::Mail
  Alumna::Mail.new(from: from, to: to, subject: subject, text: text, html: html, reply_to: reply_to)
end

describe Alumna::SMTP::Message do
  it "writes a text-only message" do
    render(mail).should eq(
      "Date: Wed, 23 Sep 2026 19:45:00 +0000\r\n" \
      "From: Alumna <noreply@example.com>\r\n" \
      "To: user@example.com\r\n" \
      "Subject: Welcome\r\n" \
      "Message-ID: <#{TOKEN}@example.com>\r\n" \
      "MIME-Version: 1.0\r\n" \
      "Content-Type: text/plain; charset=UTF-8\r\n" \
      "Content-Transfer-Encoding: quoted-printable\r\n" \
      "\r\n" \
      "Hello\r\n"
    )
  end

  it "writes text and html as multipart/alternative" do
    render(mail(to: ["a@example.com", "b@example.com"], text: "Olá\n", html: "<p>Olá</p>", reply_to: "reply@example.com")).should eq(
      "Date: Wed, 23 Sep 2026 19:45:00 +0000\r\n" \
      "From: Alumna <noreply@example.com>\r\n" \
      "To: a@example.com,\r\n b@example.com\r\n" \
      "Reply-To: reply@example.com\r\n" \
      "Subject: Welcome\r\n" \
      "Message-ID: <#{TOKEN}@example.com>\r\n" \
      "MIME-Version: 1.0\r\n" \
      "Content-Type: multipart/alternative;\r\n boundary=\"=_#{TOKEN}\"\r\n" \
      "\r\n" \
      "--=_#{TOKEN}\r\n" \
      "Content-Type: text/plain; charset=UTF-8\r\n" \
      "Content-Transfer-Encoding: quoted-printable\r\n" \
      "\r\n" \
      "Ol=C3=A1\r\n" \
      "--=_#{TOKEN}\r\n" \
      "Content-Type: text/html; charset=UTF-8\r\n" \
      "Content-Transfer-Encoding: quoted-printable\r\n" \
      "\r\n" \
      "<p>Ol=C3=A1</p>\r\n" \
      "--=_#{TOKEN}--\r\n"
    )
  end

  it "writes one text part when html is empty" do
    render(mail(html: "")).should eq(render(mail))
  end

  it "writes an empty text body" do
    render(mail(text: "")).should end_with("Content-Transfer-Encoding: quoted-printable\r\n\r\n")
  end

  it "writes an empty text part in a multipart message" do
    render(mail(text: "", html: "<p>x</p>")).should contain(
      "Content-Transfer-Encoding: quoted-printable\r\n\r\n--=_#{TOKEN}\r\nContent-Type: text/html"
    )
  end

  it "encodes a non-ASCII subject and display names" do
    output = render(mail(from: "José <jose@example.com>", to: "Ana Lúcia <ana@example.com>", subject: "Olá"))
    output.should contain("From: =?UTF-8?B?Sm9zw6k=?= <jose@example.com>\r\n")
    output.should contain("To: =?UTF-8?B?QW5hIEzDumNpYQ==?= <ana@example.com>\r\n")
    output.should contain("Subject: =?UTF-8?B?T2zDoQ==?=\r\n")
    output.should contain("Message-ID: <#{TOKEN}@example.com>\r\n")
  end

  it "uses localhost in Message-ID when from has no domain" do
    render(mail(from: "noreply")).should contain("Message-ID: <#{TOKEN}@localhost>\r\n")
  end

  it "writes Date in UTC" do
    output = String.build do |io|
      Alumna::SMTP::Message.write(io, mail, time: Time.local(2026, 9, 23, 21, 45, 0, location: Time::Location.fixed(7200)), token: TOKEN)
    end
    output.should start_with("Date: Wed, 23 Sep 2026 19:45:00 +0000\r\n")
  end

  it "uses a random token by default" do
    first = String.build { |io| Alumna::SMTP::Message.write(io, mail(html: "<p>x</p>")) }
    second = String.build { |io| Alumna::SMTP::Message.write(io, mail(html: "<p>x</p>")) }
    first_id = first.match(/Message-ID: <([0-9a-f]{32})@example\.com>/)
    second_id = second.match(/Message-ID: <([0-9a-f]{32})@example\.com>/)
    first_id.should_not be_nil
    second_id.should_not be_nil
    if first_id && second_id
      first_id[1].should_not eq(second_id[1])
      first.should contain("boundary=\"=_#{first_id[1]}\"")
    end
  end

  it "never starts a line with a dot and keeps lines short" do
    output = render(mail(subject: (["dot."] * 40).join(' '), text: ".\n.hidden\n#{"x" * 75}.y", html: ".<p>.</p>"))
    output.ends_with?("\r\n").should be_true
    output.split("\r\n").each do |line|
      line.starts_with?('.').should be_false
      line.bytesize.should be <= 78
    end
  end
end
