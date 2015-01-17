require 'hashie'

module Mumble
  class ChannelNotFound < StandardError; end
  class UserNotFound < StandardError; end
  class NoSupportedCodec < StandardError; end

  CODEC_ALPHA = 0
  CODEC_BETA  = 3
  CODEC_OPUS  = 4

  class Client
    include ThreadTools
    attr_reader :users, :channels, :ready, :codec, :max_bandwidth, :rejectmessage

    def initialize(host, port=64738, username="RubyClient", password="")
      @users, @channels = {}, {}
      @callbacks = Hash.new { |h, k| h[k] = [] }
	  @ready = false
      @max_bandwidth = 0
      @rejectmessage = ''

      @config = Mumble.configuration.dup.tap do |c|
        c.host = host
        c.port = port
        c.username = username
        c.password = password
      end
      yield(@config) if block_given?
    end

    def connect
      @conn = Connection.new @config.host, @config.port, cert_manager
      @conn.connect

      init_callbacks
      version_exchange
      authenticate

      spawn_threads :read, :ping
      connected? # just to get a nice return value
    end

    def disconnect
      @conn.disconnect
      @ready = false
      @connected = false
      @audio_streamer.destroy if @audio_streamer 
      @m2m.destroy if @m2m 
      kill_threads
      @m2m = nil
    end

    def connected?
      @connected ||= false
    end

    def cert_manager
      @cert_manager ||= CertManager.new @config.username, @config.ssl_cert_opts
    end

    def recorder
      raise NoSupportedCodec unless @codec
      @recorder ||= AudioRecorder.new self, @config.sample_rate
    end

    def get_codec
      case @codec
        when CODEC_ALPHA
          "CELT-ALPHA (0.7.0)"
        when CODEC_BETA
          "CELT-BETA (0.11.0)"
        when CODEC_OPUS
          "OPUS"
        else "[ERROR] Unknown codec: #{@codec}"
      end
    end
    
    def mumble2mumble rec
      unless @m2m == nil
        return
      end
      @m2m = Mumble2Mumble.new @codec, @conn, @config.sample_rate, @config.sample_rate / 100, 1, @config.bitrate
      if rec == true then
        on_udp_tunnel do |m|
          @m2m.process_udp_tunnel m
        end
      end
    end

    def m2m_getspeakers
      unless @m2m != nil
        return
      end
      @m2m.getspeakers
    end

    def m2m_getframe speaker
      unless @m2m != nil
        return
      end
      @m2m.getframe speaker
    end

    def m2m_writeframe frame
      unless @m2m != nil
        return
      end
      @m2m.produce frame
    end

    def m2m_getsize speaker
      unless @m2m != nil
        return 0
      end
      @m2m.getsize speaker
    end

    def mute(bool=true)
      send_user_state self_mute: bool
    end

    def player
      raise NoSupportedCodec unless @codec
      @audio_streamer ||= AudioPlayer.new @codec, @conn, @config.sample_rate, @config.bitrate
    end

    def me
      users[@session]
    end

    def get_imgmsg file
      ImgReader.msg_from_file(file)
    end

    def set_comment newcomment
      send_user_state comment: newcomment
    end

    def join_channel(channel)
      id = channel_id channel
      send_user_state(session: @session, channel_id: id)
      channels[id]
    end

    def text_user(user, string)
      session = user_session user
      send_text_message(session: [user_session(user)], message: string)
      users[session]
    end

    def text_user_img(user, file)
      text_user(user, ImgReader.msg_from_file(file))
    end

    def text_channel(channel, string)
      id = channel_id channel
      send_text_message(channel_id: [id], message: string)
      channels[id]
    end

    def text_channel_img(channel, file)
      text_channel(channel, ImgReader.msg_from_file(file))
    end

    def find_user(name)
      users.values.find { |u| u.name == name }
    end

    def find_channel(name)
      channels.values.find { |c| c.name == name }
    end

    def on_connected(&block)
      @callbacks[:connected] << block
    end

    def remove_callback(symbol, callback)
      @callbacks[symbol].delete callback
    end

    Messages.all_types.each do |msg_type|
      define_method "on_#{msg_type}" do |&block|
        @callbacks[msg_type] << block
      end

      define_method "send_#{msg_type}" do |opts|
        @conn.send_message(msg_type, opts)
      end
    end

    private
    def read
      message = @conn.read_message
      sym = message.class.to_s.demodulize.underscore.to_sym
      run_callbacks sym, Hashie::Mash.new(message.to_hash)
    end

    def ping
      send_ping timestamp: Time.now.to_i if connected?
      sleep(15)
    end

    def run_callbacks(sym, *args)
      @callbacks[sym].each { |c| c.call *args }
    end

    def init_callbacks
      on_server_sync do |message|
        @session = message.session
        @connected = true
        @callbacks[:connected].each { |c| c.call }
      end
      on_channel_state do |message|
        if channel = channels[message.channel_id]
          channel.update message.to_hash
        else
          channels[message.channel_id] = Hashie::Mash.new(message.to_hash)
        end
      end
      on_channel_remove do |message|
        channels.delete(message.channel_id)
      end
      on_user_state do |message|
        if user = users[message.session]
          user.update(message.to_hash)
        else
          users[message.session] = User.new(self, message.to_hash)
        end
      end
      on_user_remove do |message|
        if message.session == @session
            disconnect
        end
        users.delete(message.session)
      end
      on_codec_version do |message|
        codec_negotiation(message)
      end
      on_ping do |message|
        @ready = true
      end
      on_crypt_setup do |message|
        # For later implementation of UDP communication
      end
      on_reject do |message|
        @rejectmessage = message
        disconnect
      end
      on_server_config do |message|
        @max_bandwidth = message.max_bandwidth if message.max_bandwidth
      end
    end

    def version_exchange
      send_version({
        version: encode_version(1, 2, 7),
        release: "mumble-ruby #{Mumble::VERSION}",
        os: %x{uname -s}.strip,
        os_version: %x{uname -v}.strip
      })
    end

    def authenticate
      encoder = Celt::Encoder.new 32000, 180, 1
      send_authenticate({
        username: @config.username,
        password: @config.password,
        celt_versions: [encoder.bitstream_version],
        opus: true
      })
      encoder.destroy
    end

    def codec_negotiation(message)
      if message.opus
        @codec = CODEC_OPUS
      else
        encoder = Celt::Encoder.new 32000, 180, 1
        @codec =  [CODEC_ALPHA, CODEC_BETA][[message.alpha, message.beta].index(encoder.bitstream_version)]
        encoder.destroy
      end
      @m2m.set_codec @codec if @m2m != nil
      @audio_streamer.set_codec @codec if @audio_streamer != nil
    end

    def channel_id(channel)
      channel = find_channel(channel) if channel.is_a? String
      id = channel.respond_to?(:channel_id) ? channel.channel_id : channel

      raise ChannelNotFound unless @channels.has_key? id
      id
    end

    def user_session(user)
      user = find_user(user) if user.is_a? String
      id = user.respond_to?(:session) ? user.session : user

      raise UserNotFound unless @users.has_key? id
      id
    end

    def encode_version(major, minor, patch)
      (major << 16) | (minor << 8) | (patch & 0xFF)
    end
  end
end
