require 'active_support/inflector'
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

      yield self if block_given?
    end

    def connect
      @conn = Connection.new(@host, @port)
      @conn.connect

      version_exchange
      authenticate

      @read_thread = spawn_read_thread
      @ping_thread = spawn_ping_thread
    end

    def disconnect
      @read_thread.kill
      @ping_thread.kill
      @conn.disconnect
    end

    def me
      @users[@session]
    end

    def current_channel
      @channels[me.channel_id]
    end

    def mute(bool=true)
      @conn.send_message(:user_state, {
        self_mute: bool
      })
    end

    def deafen(bool=true)
      @conn.send_message(:user_state, {
        self_deaf: bool
      })
    end

    def join_channel(channel)
      @conn.send_message(:user_state, {
        session: me.session,
        channel_id: channel.channel_id
      })
    end

    def text_user(user, string)
      @conn.send_message(:text_message, {
        session: [user.session],
        message: string
      })
    end

    def text_channel(channel, string)
      @conn.send_message(:text_message, {
        channel_id: [channel.channel_id],
        message: string
      })
    end

    def user_stats(user)
      @conn.send_message(:user_stats, {
        session: user.session
      })
    end

    def find_user(name)
      @users.values.find { |u| u.name == name }
    end

    def find_channel(name)
      @channels.values.find { |u| u.name == name }
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
      end
    end

    def version_exchange
      @conn.send_message(:version, {
        version: encode_version(1, 2, 3),
        release: "mumble-ruby #{Mumble::VERSION}",
        os: %x{uname -o}.strip,
        os_version: %x{uname -v}.strip
      })
    end

    def authenticate
      @conn.send_message(:authenticate, {
        username: @username,
        password: @password,
        celt_versions: [force_signed_overflow(0x80000010)]
      })
    end

    def ping
      @conn.send_message(:ping, {
        timestamp: Time.now.to_i
      })
    end

    def force_signed_overflow(num)
      ((num + 0x80000000) & 0xFFFFFFFF) - 0x80000000
    end

    def encode_version(major, minor, patch)
      (major << 16) | (minor << 8) | (patch & 0xFF)
    end

    def decode_version(version)
      return version >> 16, version >> 8 & 0xFF, version & 0xFF
    end
  end
end
