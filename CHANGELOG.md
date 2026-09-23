# Changelog

## 0.1.0 - 2026-09-23

### Added
* **smtp:** `Alumna::SMTP < Alumna::Mailer`. `send` opens one connection, runs one SMTP dialog (EHLO, STARTTLS or implicit TLS, AUTH PLAIN or LOGIN, MAIL, RCPT, DATA, QUIT), and closes it. Success returns `nil`. A server refusal, a network, TLS, or timeout failure, or an invalid reply returns `Alumna::MailError`.
* **smtp:** TLS modes `:starttls` (default, port 587), `:implicit` (port 465), and `:none` (port 25). No downgrade: `:starttls` fails when the server does not offer STARTTLS. No AUTH without TLS. The certificate check uses `tls_context` (default: system CAs).
* **smtp:** `Alumna::SMTP.from_env` reads `SMTP_HOST`, and the optional `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `SMTP_TLS`.
* **smtp:** The message streams to the socket: UTF-8 quoted-printable bodies, `multipart/alternative` when `html` is set, RFC 2047 encoded words for a non-ASCII subject or display name, `Date`, and `Message-ID`.
* **smtp:** A refused recipient fails the whole send. A non-ASCII envelope address returns `MailError` before a connection opens. `MailError` text does not include the username or the password.
* **smtp:** Configuration mistakes raise `ArgumentError` (empty host, bad port, only one of username and password, AUTH with `tls: :none`, bad `helo_name`, a timeout that is not positive).
* **ci:** Format, spec, `preview_mt` with `execution_context`, and kcov 100% on `src/`. Specs use a scripted SMTP server on loopback and a test certificate. Default CI does not use the network.
