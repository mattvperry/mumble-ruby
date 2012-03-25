require 'socket'
require 'openssl'
require 'thread'

module Mumble
  class Connection
    def initialize(host, port)
      @host = host
      @port = port
      @write_lock = Mutex.new
    end

    def connect
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      tcp_sock = TCPSocket.new @host, @port
      @sock = OpenSSL::SSL::SSLSocket.new tcp_sock, context
      @sock.connect
    end

    def read_message
      header = read_data 6
      type, len = header.unpack Messages::HEADER_FORMAT
      Messages.from_type type, read_data(len)
    end

    def send_message(message)
      type = Messages.get_type(message)
      serial = message.serialize_to_string
      header = [type, serial.size].pack Messages::HEADER_FORMAT
      send_data(header + serial)
    end

    private
    def send_data(data)
      @write_lock.synchronize do
        @sock.syswrite data
      end
    end

    def read_data(len)
      @sock.sysread len
    end
  end
end
