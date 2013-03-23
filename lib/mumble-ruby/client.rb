require 'thread'

module Mumble
  class ChannelNotFound < StandardError; end
  class UserNotFound < StandardError; end
  class NoSupportedCodec < StandardError; end

  CODEC_ALPHA = 0
  CODEC_BETA = 3

  class Client
    attr_reader :host, :port, :username, :password, :users, :channels

    def initialize(host, port=64738, username="Ruby Client", password="")
      @host = host
      @port = port
      @username = username
      @password = password
      @users, @channels = {}, {}
      @callbacks = Hash.new { |h, k| h[k] = [] }
    end

    def connect
      @conn = Connection.new @host, @port
      @conn.connect

      create_encoder
      version_exchange
      authenticate
      init_callbacks

      @read_thread = spawn_thread :read
      @ping_thread = spawn_thread :ping
    end

    def disconnect
      @encoder.destroy
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

    def stream_raw_audio(file)
      raise NoSupportedCodec unless @codec
      AudioStream.new(@codec, 0, @encoder, file, @conn)
    end

    Messages.all_types.each do |msg_type|
      define_method "on_#{msg_type}" do |&block|
        @callbacks[msg_type] << block
      end

      define_method "send_#{msg_type}" do |opts|
        @conn.send_message(msg_type, opts)
      end
    end

    def mute(bool=true)
      send_user_state self_mute: bool
    end

    def deafen(bool=true)
      send_user_state self_deaf: bool
    end

    def join_channel(channel)
      send_user_state({
        session: me.session,
        channel_id: channel_id(channel)
      })
    end

    def text_user(user, string)
      send_text_message({
        session: [user_session(user)],
        message: string
      })
    end

    def text_channel(channel, string)
      send_text_message({
        channel_id: [channel_id(channel)],
        message: string
      })
    end

    def user_stats(user)
      send_user_stats session: user_session(user)
    end

    def find_user(name)
      @users.values.find { |u| u.name == name }
    end

    def find_channel(name)
      @channels.values.find { |u| u.name == name }
    end

    private
    def spawn_thread(sym)
      Thread.new { loop { send sym } }
    end

    def read
      message = @conn.read_message
      sym = message.class.to_s.demodulize.underscore.to_sym
      run_callbacks sym, message
    end

    def ping
      send_ping timestamp: Time.now.to_i
      sleep(20)
    end

    def run_callbacks(sym, *args)
      @callbacks[sym].each { |c| c.call *args }
    end

    def init_callbacks
      on_server_sync do |message|
        @session = message.session
      end
      on_channel_state do |message|
        @channels[message.channel_id] = message
      end
      on_channel_remove do |message|
        @channels.delete(message.channel_id)
      end
      on_user_state do |message|
        if @users[message.session]
          merged = merge_messages @users[message.session], message
          @users[message.session] = merged
        else
          @users[message.session] = message
        end
      end
      on_user_remove do |message|
        @users.delete(message.session)
      end
      on_codec_version do |message|
        codec_negotiation(message.alpha, message.beta)
      end
    end

    def merge_messages(a, b)
      a, b = a.dup, b.dup
      raise "Tried to merge messages of different types: #{a.class} and #{b.class}" unless a.class == b.class
      fields = b.fields.values.map { |f| f.name }

      fields.each do |field|
        a[field] = b[field] if b.has_field? field
      end
      a      
    end

    def create_encoder
      @encoder = Celt::Encoder.new 48000, 480, 1
      @encoder.prediction_request = 0
      @encoder.vbr_rate = 60000
    end

    def version_exchange
      send_version({
        version: encode_version(1, 2, 3),
        release: "mumble-ruby #{Mumble::VERSION}",
        os: %x{uname -s}.strip,
        os_version: %x{uname -v}.strip
      })
    end

    def authenticate
      send_authenticate({
        username: @username,
        password: @password,
        celt_versions: [@encoder.bitstream_version]
      })
    end

    def codec_negotiation(alpha, beta)
      @codec = case @encoder.bitstream_version
               when alpha then Mumble::CODEC_ALPHA
               when beta then Mumble::CODEC_BETA
               end
    end

    def channel_id(channel)
      id = case channel
           when Messages::ChannelState
             channel.channel_id
           when Fixnum
             channel
           when String
             find_channel(channel).channel_id
           end

      raise ChannelNotFound unless @channels.has_key? id
      id
    end

    def user_session(user)
      id = case user
           when Messages::ChannelState
             user.session
           when Fixnum
             user
           when String
             find_user(user).session
           end

      raise UserNotFound unless @users.has_key? id
      id
    end

    def encode_version(major, minor, patch)
      (major << 16) | (minor << 8) | (patch & 0xFF)
    end
  end
end
