require 'socket'
require 'openssl'
require 'thread'

module Mumble
  class Connection
    def initialize(host, port, cert_manager)
      @host = host
      @port = port
      @cert_manager = cert_manager
      @write_lock = Mutex.new
    end

    def connect
      context = OpenSSL::SSL::SSLContext.new(:TLSv1)
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      [:key, :cert].each { |s| context.send("#{s}=", @cert_manager.send(s)) }
      tcp_sock = TCPSocket.new @host, @port
      @sock = OpenSSL::SSL::SSLSocket.new tcp_sock, context
      @sock.connect
    end

    def disconnect
      @sock.close
    end

    def read_message
      header = read_data 6
      type, len = header.unpack Messages::HEADER_FORMAT
      data = read_data len
      if type == message_type(:udp_tunnel)
        # UDP Packet -- No Protobuf
        message = message_class(:udp_tunnel).new
        message.packet = data
      else
        message = message_raw type, data
      end
      message
    end

    def send_udp_packet(packet)
      header = [message_type(:udp_tunnel), packet.length].pack Messages::HEADER_FORMAT
      send_data(header + packet)
    end

    def send_message(sym, attrs)
      type, klass = message(sym)
      message = klass.new
      attrs.each { |k, v| message.send("#{k}=", v) }
      serial = message.serialize_to_string
      header = [type, serial.size].pack Messages::HEADER_FORMAT
      send_data(header + serial)
    end

    private
    def send_data(data)
      @write_lock.synchronize do
        @sock.write data
      end
    end

    def read_data(len)
      @sock.read len
    end

    def message(obj)
      return message_type(obj), message_class(obj)
    end

    def message_type(obj)
      if obj.is_a? Protobuf::Message
        obj = obj.class.to_s.demodulize.underscore.to_sym
      end
      Messages.sym_to_type(obj)
    end

    def message_class(obj)
      Messages.type_to_class(message_type(obj))
    end

    def message_raw(type, data)
      Messages.raw_to_obj(type, data)
    end
  end
end
