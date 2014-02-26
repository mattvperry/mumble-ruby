require 'openssl'
require 'fileutils'

module Mumble
  class CertManager
    attr_reader :key, :cert

    CERT_STRING = "/C=%s/O=%s/OU=%s/CN=%s"

    def initialize(username, opts)
      @cert_dir = File.join(opts[:cert_dir], "#{username.downcase}_cert")
      @username = username
      @opts = opts

      FileUtils.mkdir_p @cert_dir
      setup_key
      setup_cert
    end

    [:private_key, :public_key, :cert].each do |sym|
      define_method "#{sym}_path" do
        File.join(@cert_dir, "#{sym}.pem")
      end
    end

    private
    def setup_key
      if File.exists?(private_key_path)
        @key ||= OpenSSL::PKey::RSA.new File.read(private_key_path)
      else
        @key ||= OpenSSL::PKey::RSA.new 2048
        File.write private_key_path, key.to_pem
        File.write public_key_path, key.public_key.to_pem
      end
    end

    def setup_cert
      if File.exists?(cert_path)
        @cert ||= OpenSSL::X509::Certificate.new File.read(cert_path)
      else
        @cert ||= OpenSSL::X509::Certificate.new

        subject = CERT_STRING % [@opts[:country_code], @opts[:organization], @opts[:organization_unit], @username]

        cert.subject = cert.issuer = OpenSSL::X509::Name.parse(subject)
        cert.not_before = Time.now
        cert.not_after = Time.new + 365 * 24 * 60 * 60 * 5
        cert.public_key = key.public_key
        cert.serial = rand(65535) + 1
        cert.version = 2

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = cert

        cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
        cert.add_extension(ef.create_extension("keyUsage", "keyCertSign, cRLSign", true))
        cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
        cert.add_extension(ef.create_extension("authorityKeyIdentifier", "keyid:always", false))

        cert.sign key, OpenSSL::Digest::SHA256.new

        File.write cert_path, cert.to_pem
      end
    end
  end
end
