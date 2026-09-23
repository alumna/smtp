# SMTP mailer for Alumna Backend.
# `Alumna::SMTP < Alumna::Mailer` loads from here. It needs Alumna 0.10.1 or later:
# Mail.new rejects CR and LF in header values, so the SMTP writer can trust them.
require "alumna"
require "./smtp"
