require 'thread'

module Mumble
  class Client
    attr_reader :host, :port, :username, :password

    def initialize(host, port=64738, username="Ruby Client", password="")
      @host = host
      @port = port
      @username = username
      @password = password
    end

    def connect
      @conn = Connection.new(@host, @port)
      @conn.connect

      version_exchange
      authenticate

      read_thread
      ping_thread
    end

    private
    def read_thread
      Thread.new do
      end
    end

    def ping_thread
      Thread.new do
      end
    end

    def version_exchange
      message = Messages::Version.new
      message.version = encode_version(1, 2, 3)
      message.release = "mumble-ruby #{Mumble::VERSION}"
      message.os = %x{uname -o}.strip
      message.os_version = %x{uname -v}.strip
      @conn.send_message(message)
    end

    def authenticate
      message = Messages::Authenticate.new
      message.username = @username
      message.password = @password
      message.celt_versions << -2147483637
      @conn.send_message(message)
    end

    def encode_version(major, minor, patch)
      (major << 16) | (minor << 8) | (patch & 0xFF)
    end

    def decode_version(version)
      return version >> 16, version >> 8 & 0xFF, version & 0xFF
    end
  end
end
