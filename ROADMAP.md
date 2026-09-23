# Alumna SMTP — roadmap

Official SMTP implementation of `Alumna::Mailer`. Published at [alumna/smtp](https://github.com/alumna/smtp) **0.1.0**.

Not a Service adapter. No `AdapterSuite`. Amazon SES over its HTTP API is a different shard ([alumna/ses](https://github.com/alumna/ses)).

## 0.1.0

* `Alumna::SMTP < Alumna::Mailer`. One method: `send`.
* One new connection for each `send`. Stdlib `TCPSocket` and `OpenSSL`. No other dependency.
* TLS modes `:starttls` (default), `:implicit`, and `:none`. No downgrade. No AUTH without TLS.
* AUTH `PLAIN` and `LOGIN`.
* UTF-8 quoted-printable bodies, `multipart/alternative` for text + html, RFC 2047 headers.
* A refused recipient fails the whole send.
* `from_env` reads `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `SMTP_TLS`.
* Config mistakes raise `ArgumentError`. Server, network, TLS, and timeout failures return `Alumna::MailError`.
* Specs use a scripted SMTP server on loopback. Default CI does not use the network.
* GitHub CI: format, spec, `preview_mt` + `execution_context`, kcov 100% on `src/`.

## Later

* Attachments, cc, and bcc (they need a change to Backend `Alumna::Mail` first).
* Connection pool (keep-alive, `RSET` between messages).
* `PIPELINING`.
* `XOAUTH2` (Gmail and Microsoft 365 tokens).
* SMTPUTF8 (non-ASCII addresses).
* DKIM signing.
