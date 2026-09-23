require "./spec_helper"

# The SMTP writer puts from, to, reply_to, and subject into headers and commands
# without a second check. This spec fails when the installed Alumna is older than 0.10.1.
describe "Alumna dependency" do
  it "rejects CR or LF in header values" do
    expect_raises(ArgumentError, "subject must not contain CR or LF") do
      Alumna::Mail.new(
        from: "from@example.com",
        to: "to@example.com",
        subject: "Hello\r\nBcc: x@example.com",
        text: "Plain",
      )
    end
  end
end
