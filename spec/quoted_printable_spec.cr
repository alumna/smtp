require "./spec_helper"

private def qp(text : String) : String
  String.build { |io| Alumna::SMTP::QuotedPrintable.write(io, text) }
end

# Reverses quoted-printable, for round-trip checks. Hard breaks come back as CRLF.
private def qp_decode(encoded : String) : String
  soft = encoded.gsub("=\r\n", "")
  bytes = IO::Memory.new
  index = 0
  while index < soft.bytesize
    byte = soft.byte_at(index)
    if byte == '='.ord
      bytes.write_byte(soft[index + 1, 2].to_u8(16))
      index += 3
    else
      bytes.write_byte(byte)
      index += 1
    end
  end
  String.new(bytes.to_slice)
end

describe Alumna::SMTP::QuotedPrintable do
  it "writes nothing for an empty text" do
    qp("").should eq("")
  end

  it "keeps printable ASCII and ends with CRLF" do
    qp("Hello, world!").should eq("Hello, world!\r\n")
  end

  it "encodes the equals sign" do
    qp("a=b").should eq("a=3Db\r\n")
  end

  it "encodes UTF-8 bytes in upper-case hex" do
    qp("Olá").should eq("Ol=C3=A1\r\n")
  end

  it "encodes control bytes and DEL" do
    qp("a\u0000b\u007Fc").should eq("a=00b=7Fc\r\n")
  end

  it "changes LF, CR, and CRLF to one CRLF each" do
    qp("a\nb\rc\r\nd").should eq("a\r\nb\r\nc\r\nd\r\n")
  end

  it "keeps empty lines" do
    qp("a\n\nb\n").should eq("a\r\n\r\nb\r\n")
  end

  it "does not add a CRLF after a final line break" do
    qp("a\r\n").should eq("a\r\n")
  end

  it "encodes a space or tab before a line break or at the end" do
    qp("a \nb\t\r\nc ").should eq("a=20\r\nb=09\r\nc=20\r\n")
  end

  it "keeps a space or tab inside a line" do
    qp("a b\tc").should eq("a b\tc\r\n")
  end

  it "encodes a dot at the start of a line" do
    qp(".\n..x\na.b").should eq("=2E\r\n=2E.x\r\na.b\r\n")
  end

  it "soft-breaks after 75 characters" do
    qp("a" * 80).should eq("#{"a" * 75}=\r\naaaaa\r\n")
  end

  it "keeps a line of exactly 75 characters" do
    qp("a" * 75).should eq("#{"a" * 75}\r\n")
  end

  it "does not split an encoded triplet at a soft break" do
    qp("#{"a" * 74}á").should eq("#{"a" * 74}=\r\n=C3=A1\r\n")
  end

  it "encodes a dot that a soft break moves to the start of a line" do
    qp("#{"a" * 75}.b").should eq("#{"a" * 75}=\r\n=2Eb\r\n")
  end

  it "keeps every line within 76 characters and round-trips the text" do
    text = "Olá, #{"mundo " * 40}.\n= fim \t\n#{"é" * 50}"
    encoded = qp(text)
    encoded.split("\r\n").each { |line| line.bytesize.should be <= 76 }
    encoded.split("\r\n").each { |line| line.starts_with?('.').should be_false }
    qp_decode(encoded).should eq(text.gsub("\n", "\r\n") + "\r\n")
  end
end
