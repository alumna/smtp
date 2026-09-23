require "./spec_helper"

private def text_header(value : String) : String
  String.build { |io| Alumna::SMTP::Header.write_text(io, "Subject", value) }
end

private def address_header(value : String) : String
  String.build { |io| Alumna::SMTP::Header.write_address(io, "From", value) }
end

private def encoded(text : String) : String
  "=?UTF-8?B?#{Base64.strict_encode(text)}?="
end

describe Alumna::SMTP::Header do
  describe ".write_text" do
    it "keeps a short ASCII value" do
      text_header("Hello").should eq("Subject: Hello\r\n")
    end

    it "folds a long ASCII value at a space" do
      words = (["word"] * 20).join(' ')
      header = text_header(words)
      # "Subject: " (9) + 14 words and 13 spaces (69) = 78, the fold limit.
      header.should eq("Subject: #{(["word"] * 14).join(' ')}\r\n #{(["word"] * 6).join(' ')}\r\n")
      header.split("\r\n").each { |line| line.bytesize.should be <= 78 }
    end

    it "does not fold before a space that another space follows" do
      value = "#{"a" * 67}  b"
      text_header(value).should eq("Subject: #{"a" * 67} \r\n b\r\n")
    end

    it "does not fold before trailing spaces" do
      value = "#{"a" * 69}   "
      text_header(value).should eq("Subject: #{value}\r\n")
    end

    it "does not fold before the first byte" do
      value = " #{"a" * 80}"
      text_header(value).should eq("Subject: #{value}\r\n")
    end

    it "encodes a non-ASCII value" do
      text_header("Olá").should eq("Subject: =?UTF-8?B?T2zDoQ==?=\r\n")
    end

    it "encodes a value with a control byte" do
      text_header("a\u0000b").should eq("Subject: #{encoded("a\u0000b")}\r\n")
    end

    it "keeps a tab in an ASCII value" do
      text_header("a\tb").should eq("Subject: a\tb\r\n")
    end

    it "encodes an ASCII word too long to fold" do
      value = "a" * 990
      header = text_header(value)
      header.should start_with("Subject: =?UTF-8?B?")
      header.split("\r\n").each { |line| line.bytesize.should be <= 76 }
    end

    it "splits encoded words on UTF-8 character boundaries" do
      value = "é" * 30
      header = text_header(value)
      header.should eq("Subject: #{encoded("é" * 19)}\r\n #{encoded("é" * 11)}\r\n")
      header.split("\r\n").each { |line| line.bytesize.should be <= 76 }
    end

    it "splits a 4-byte character without a cut" do
      value = "a" * 37 + "😀" + "b"
      text_header(value).should eq("Subject: #{encoded("a" * 37)}\r\n #{encoded("😀b")}\r\n")
    end
  end

  describe ".write_address" do
    it "keeps a bare address" do
      address_header("a@example.com").should eq("From: a@example.com\r\n")
    end

    it "keeps an ASCII display name" do
      address_header("Alumna <a@example.com>").should eq("From: Alumna <a@example.com>\r\n")
    end

    it "keeps a quoted ASCII display name" do
      address_header(%("Doe, John" <a@example.com>)).should eq(%(From: "Doe, John" <a@example.com>\r\n))
    end

    it "encodes a non-ASCII display name" do
      address_header("José <a@example.com>").should eq("From: #{encoded("José")} <a@example.com>\r\n")
    end

    it "removes quotes around a non-ASCII display name" do
      address_header(%(  "Silva, José"  <a@example.com>)).should eq("From: #{encoded("Silva, José")} <a@example.com>\r\n")
    end

    it "keeps a value with < that does not end with >" do
      address_header("a<b@example.com").should eq("From: a<b@example.com\r\n")
    end
  end

  describe ".write_addresses" do
    it "puts each address after the first on a folded line" do
      header = String.build do |io|
        Alumna::SMTP::Header.write_addresses(io, "To", ["a@example.com", "José <b@example.com>", "c@example.com"])
      end
      header.should eq("To: a@example.com,\r\n #{encoded("José")} <b@example.com>,\r\n c@example.com\r\n")
    end
  end

  describe ".address" do
    it "returns the address in angle brackets" do
      String.new(Alumna::SMTP::Header.address("Name <a@example.com>")).should eq("a@example.com")
    end

    it "returns a bare address as is" do
      String.new(Alumna::SMTP::Header.address("a@example.com")).should eq("a@example.com")
    end

    it "returns the value when there is no opening angle bracket" do
      String.new(Alumna::SMTP::Header.address("a@example.com>")).should eq("a@example.com>")
    end
  end

  describe ".domain" do
    it "returns the part after the last @" do
      String.new(Alumna::SMTP::Header.domain("Name <a@b@example.com>")).should eq("example.com")
    end

    it "is empty without @" do
      Alumna::SMTP::Header.domain("nobody").empty?.should be_true
    end
  end
end
