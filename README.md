# Alumna SMTP

[![Crystal CI](https://github.com/alumna/smtp/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/smtp/actions/workflows/ci.yml) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fsmtp%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/smtp)

SMTP mailer for the [Alumna Backend Framework](https://github.com/alumna/backend). Published at [alumna/smtp](https://github.com/alumna/smtp) **0.1.0**.

`Alumna::SMTP` implements `Alumna::Mailer`. The only method is `send`. This shard is not a Service adapter.

`send` delivers one message to an SMTP server: Amazon SES SMTP, Postmark, Mailgun, SendGrid, Gmail, Microsoft 365, Postfix, or Mailpit. The shard uses stdlib `TCPSocket` and `OpenSSL`. There is no other dependency.

The app code does not change when you change the mailer. Replace `Alumna::SES.from_env` with `Alumna::SMTP.from_env` (or the reverse), or use `Alumna::MemoryMailer` in specs.

See [ROADMAP.md](ROADMAP.md).

---

## Table of Contents

1. [Installation](#1-installation)
2. [Configuration](#2-configuration)
3. [TLS](#3-tls)
4. [Send](#4-send)
5. [Message format](#5-message-format)
6. [Errors](#6-errors)
7. [Security](#7-security)
8. [Testing](#8-testing)
9. [Limits](#9-limits)
10. [License](#10-license)

---

## 1. Installation

Add it to your `shard.yml`:

```yaml
dependencies:
  alumna:
    github: alumna/backend
    version: ~> 0.10.1
  alumna-smtp:
    github: alumna/smtp
    version: ~> 0.1.0
```

Then run `shards install`.

```crystal
require "alumna-smtp"
```

Needs Alumna Backend **0.10.1** or later. That version rejects CR and LF in the header fields of `Alumna::Mail`, and this shard depends on that check. Crystal **1.20.2** or later.

For development purposes, you can use a gitignored `shard.override.yml` that refers to a locally changed Alumna Backend, like with:

```yaml
dependencies:
  alumna:
    path: ../backend
```

`shard.yml` keeps `github: alumna/backend`. Do not put `path:` in `shard.yml`.

---

## 2. Configuration

### From the environment

`from_env` reads process `ENV`. There is no dotenv parser. Do not commit secrets.

| Name | Required | Role |
|---|---|---|
| `SMTP_HOST` | yes | Server host name, for example `email-smtp.sa-east-1.amazonaws.com` |
| `SMTP_PORT` | no | Server port. The default follows `SMTP_TLS` (587, 465, or 25) |
| `SMTP_USERNAME` | no | AUTH user name. Set it together with `SMTP_PASSWORD` |
| `SMTP_PASSWORD` | no | AUTH password |
| `SMTP_TLS` | no | `starttls` (default), `implicit`, or `none`. Not case sensitive |

```crystal
mailer = Alumna::SMTP.from_env
```

A missing or empty `SMTP_HOST` raises `ArgumentError`. An optional variable that is set but empty raises `ArgumentError`. Omit the variable when there is no value. A `SMTP_PORT` that is not a number, or a `SMTP_TLS` that is not one of the three modes, raises `ArgumentError`.

`from_env` also accepts `helo_name:` and `tls_context:` (see below).

### With arguments

```crystal
mailer = Alumna::SMTP.new(
  host: "smtp.example.com",
  port: 587,
  tls: :starttls,
  username: ENV["SMTP_USERNAME"],
  password: ENV["SMTP_PASSWORD"],
)
```

| Argument | Default | Rule |
|---|---|---|
| `host` | — | Required. `""` raises `ArgumentError` |
| `port` | 587, 465, or 25 (from `tls`) | 1 to 65535 |
| `tls` | `:starttls` | `:starttls`, `:implicit`, or `:none`. See [TLS](#3-tls) |
| `username`, `password` | `nil` | Set both or neither. `""` raises `ArgumentError`. Not allowed with `tls: :none` |
| `helo_name` | `System.hostname` | The name in the EHLO command. Printable ASCII with no space |
| `tls_context` | `OpenSSL::SSL::Context::Client.new` | Checks the server certificate with the system CAs |
| `connect_timeout` | 10 seconds | Also the DNS timeout. Must be positive |
| `read_timeout` | 30 seconds | For each read from the server. Must be positive |
| `write_timeout` | 30 seconds | For each write to the server. Must be positive |

A configuration mistake raises `ArgumentError` in `new` or `from_env`. It does not wait for `send`.

---

## 3. TLS

| Mode | Default port | What happens |
|---|---|---|
| `:starttls` | 587 | Plain TCP, then `STARTTLS`, then TLS before `AUTH` and `MAIL` |
| `:implicit` | 465 | TLS from the first byte |
| `:none` | 25 | No TLS. Use it only for a local or trusted network (Mailpit, a local relay). `AUTH` is not allowed |

With `:starttls`, a server that does not offer `STARTTLS` makes `send` return `MailError`. The shard never continues without TLS. There is no downgrade.

The server certificate must be valid for `host`. The default `tls_context` uses the system CAs and checks the host name. For a private CA:

```crystal
context = OpenSSL::SSL::Context::Client.new
context.ca_certificates = "/etc/ssl/private-ca.pem"

mailer = Alumna::SMTP.new(host: "mail.internal", tls_context: context)
```

The same argument accepts a client certificate (`context.certificate_chain =` and `context.private_key =`).

AUTH uses `PLAIN` when the server offers it, else `LOGIN`. A server that offers neither makes `send` return `MailError`. AUTH only runs over TLS.

---

## 4. Send

```crystal
require "alumna-smtp"

mailer = Alumna::SMTP.from_env
mail = Alumna::Mail.new(
  from: "Alumna <noreply@example.com>",
  to: ["a@example.com", "Bee <b@example.com>"],
  subject: "Verify your email",
  text: "Open this link.",
  html: "<p>Open this link.</p>",
  reply_to: "reply@example.com",
)
result = mailer.send(mail)
if result.is_a?(Alumna::MailError)
  # The send failed. Do not log the password.
end
```

`nil` means the server accepted the message (`250` after the data). `Alumna::MailError` means the server refused it, or the connection, the TLS handshake, or a timeout failed. `send` returns that struct. The call does not raise it.

Each `send` opens one new connection, runs one SMTP dialog, and closes the connection. There is no shared connection state, so concurrent `send` calls from many fibers are safe (also with `preview_mt` and execution contexts).

The dialog is: greeting, `EHLO`, `STARTTLS` and `EHLO` again (with `:starttls`), `AUTH` (when a username is set), `MAIL FROM`, one `RCPT TO` for each address in `to`, `DATA`, the message, `QUIT`. There is no `HELO` fallback.

If the server refuses one recipient, the whole send fails. The shard sends `RSET` and `QUIT`, and returns `MailError` with that address. No recipient gets the message.

Call `send` from `after_commit` when the message must follow a successful write. Keep cache and the logger on `before` and `after`. If the rule returns `ServiceError`, the client sees an error. The adapter write already completed.

```crystal
app.after_commit on: :mutate do |ctx|
  failed = mailer.send(mail)
  next Alumna::ServiceError.internal(failed.message) if failed.is_a?(Alumna::MailError)
end
```

---

## 5. Message format

The message streams to the socket. The shard does not build the full message in memory.

| Mail field | Message | Rule |
|---|---|---|
| `from` | `From` header, `MAIL FROM` | Required. The envelope uses the address in `<...>` |
| `to` | `To` header, `RCPT TO` | One or more. Each address after the first is on its own folded header line |
| `reply_to` | `Reply-To` header | Optional |
| `subject` | `Subject` header | ASCII is folded at 78 characters. Other text uses RFC 2047 encoded words |
| `text` | `text/plain` part | UTF-8, quoted-printable. `""` is sent |
| `html` | `text/html` part | Optional. `nil` and `""` omit the HTML part |

With `html`, the message is `multipart/alternative` (text first, HTML last). Without it, the message is one `text/plain` part.

The shard also writes `Date` (UTC), `Message-ID` (random, on the domain of `from`, or `localhost` when `from` has no domain), and `MIME-Version`.

An address can be bare (`user@example.com`) or have a display name (`User <user@example.com>`). A display name that is not ASCII is RFC 2047 encoded. The header keeps the rest of the value as given.

Line breaks in `text` and `html` become CRLF. Each body line has 76 characters or less. A line that starts with `.` is safe: quoted-printable writes it as `=2E`.

---

## 6. Errors

`Alumna::MailError` is a struct with `message`. `to_s` writes that message. It is not `StoreError` and it is not an exception. Map it to `ServiceError.internal` when the HTTP response must fail.

| Result | When |
|---|---|
| `nil` | The server replied `250` after the data |
| `MailError` `"SMTP send failed (code): text"` | A reply that is not the expected code (greeting, `EHLO`, `STARTTLS`, `AUTH`, `MAIL`, `DATA`, or after the data) |
| `MailError` `"SMTP send failed (code) for address: text"` | The server refused a recipient |
| `MailError` `"SMTP server does not offer STARTTLS"` | `tls: :starttls`, and `EHLO` has no `STARTTLS` |
| `MailError` `"SMTP server offers no supported AUTH mechanism"` | A username is set, and `EHLO` offers neither `PLAIN` nor `LOGIN` |
| `MailError` `"SMTP server sent an invalid reply"` | A reply line that does not follow RFC 5321, a line longer than 1024 bytes, or a reply with more than 100 lines |
| `MailError` `"SMTP address is not supported: address"` | An address in `from` or `to` with a non-ASCII byte, a space, `<`, or `>`. Returned before a connection opens |
| `MailError` `"mail send failed"` | DNS, connection, TLS, or timeout failure |
| `ArgumentError` | A configuration mistake in `new` or `from_env` |

`MailError` text does not include the username or the password (also not in their base64 AUTH forms). They are replaced with `[redacted]`.

Empty `from`, empty `to`, empty `subject`, empty `reply_to`, or a CR or LF in those fields raises `ArgumentError` in `Mail.new`, before `send`.

---

## 7. Security

- Use `:starttls` or `:implicit` for any server that is not on the same machine or a trusted network.
- The shard does not continue without TLS when `:starttls` is set, and it does not send `AUTH` without TLS.
- Keep the certificate check. Do not set `verify_mode` to `NONE` on the `tls_context` in production.
- Do not log the password. Do not log the message body. It can contain private text.
- `MailError` replaces the username and the password with `[redacted]`.
- Keep credentials in process `ENV`. Do not commit them.
- `Mail.new` rejects CR and LF in header fields, so a value cannot add a header or an SMTP command. `helo_name` must be printable ASCII with no space.
- A reply line has a limit of 1024 bytes and a reply has a limit of 100 lines, so a bad server cannot fill memory.

---

## 8. Testing

Application specs use `Alumna::MemoryMailer` from Backend. They do not need this shard or a server.

Specs in this repository run the real client against a scripted SMTP server on `127.0.0.1` (a random port). The TLS specs use a self-signed test certificate in `spec/fixtures/`. That key is only for specs. Default CI does not use the network and does not read secrets.

Set `SMTP_LIVE=1` plus `SMTP_LIVE_FROM` and `SMTP_LIVE_TO` to run the live example. It stays pending when the flag is unset. `from_env` then also needs `SMTP_HOST` and the other `SMTP_*` variables that your server needs.

To see real messages on your machine, run [Mailpit](https://mailpit.axllent.org):

```sh
docker run -d --rm --name mailpit -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 axllent/mailpit
```

```crystal
mailer = Alumna::SMTP.new(host: "127.0.0.1", port: 1025, tls: :none)
```

Then open `http://localhost:8025`.

GitHub Actions on [alumna/smtp](https://github.com/alumna/smtp/actions/workflows/ci.yml):

- Format check
- Specs
- Specs with `preview_mt` and `execution_context`
- kcov on `src/` (line-rate 1.000)

---

## 9. Limits

This release has no attachments, no cc or bcc (Backend `Mail` has none), no SMTPUTF8 (non-ASCII addresses), no connection pool, no `PIPELINING`, no DKIM signing, and no `XOAUTH2`. See [ROADMAP.md](ROADMAP.md).

---

## 10. License

MIT
