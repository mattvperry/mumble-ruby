require 'thread'

module Mumble
  class Client
    attr_reader :host, :port, :username, :password, :users, :channels

    def initialize(host, port=64738, username="Ruby Client", password="")
      @host = host
      @port = port
      @username = username
      @password = password
      @users, @channels = {}, {}
      Thread.abort_on_exception = true
    end

    def connect
      @conn = Connection.new(@host, @port)
      @conn.connect

      version_exchange
      authenticate

      @read_thread = spawn_read_thread
      @ping_thread = spawn_ping_thread
    end

    def me
      @users[@session]
    end

    def join_channel(channel)
      me.channel_id = channel.channel_id
      move = Messages::UserState.new
      move.session = me.session
      move.channel_id = me.channel_id
      @conn.send_message(move)
    end

    def text_user(user, string)
      message = Messages::TextMessage.new
      message.session << user.session
      message.message = string
      @conn.send_message(message)
    end

    def text_channel(channel, string)
      message = Messages::TextMessage.new
      message.channel_id << channel.channel_id
      message.message = string
      @conn.send_message(message)
    end

    private
    def spawn_read_thread
      Thread.new do
        while 1
          message = @conn.read_message
          process_message(message)
        end
      end
    end

    def spawn_ping_thread
      Thread.new do
        while 1
          ping
          sleep(20)
        end
      end
    end

    def process_message(message)
      case message
      when Messages::ServerSync
        @session = message.session
      when Messages::ChannelState
        @channels[message.channel_id] = message
      when Messages::ChannelRemove
        @channels.delete(message.channel_id)
      when Messages::UserState
        @users[message.session] = message
      when Messages::UserRemove
        @users.delete(message.session)
      when Messages::TextMessage
        # Callback
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

    def ping
      message = Messages::Ping.new
      message.timestamp = Time.now.to_i
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
