require 'thread'
require 'hashie'

module Mumble
  class ChannelNotFound < StandardError; end
  class UserNotFound < StandardError; end
  class NoSupportedCodec < StandardError; end

  class Client
    attr_reader :users, :channels, :connected

    CODEC_OPUS = 4

    def initialize(host, port=64738, username="RubyClient", password="")
      @users, @channels = {}, {}
      @callbacks = Hash.new { |h, k| h[k] = [] }
      @connected = false
      @rsh = nil
      @recordfile = nil
	  @cert_manager = nil

      @config = Mumble.configuration.dup.tap do |c|
        c.host = host
        c.port = port
        c.username = username
        c.password = password
      end
      yield(@config) if block_given?
    end

    def connect
	  if @cert_manager == nil then
	    @cert_manager = CertManager.new(@config.username, @config.ssl_cert_opts)
	  end
      @conn = Connection.new @config.host, @config.port, @cert_manager
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
			unless @rsh == nil then
				@rsh.destroy
			end
			unless @m2m == nil then
				@m2m.destroy
			end
      @conn.disconnect
      @connected = false
	  @m2m = nil
	  @rsh = nil
    end

    def me
      users[@session]
    end

    def current_channel
      channels[me.channel_id]
    end

    def stream_raw_audio(file)
      raise NoSupportedCodec unless @codec
      AudioStream.new(@codec, 0, @encoder, file, @conn)
    end

	def receive_raw_audio(file)
	  unless @rsh == nil then
	    return
	  end
	  @rsh = ReceiveStreamHandler.new file, @config.sample_rate, @config.sample_rate / 100, 1
	  on_udp_tunnel do |m|
	    @rsh.process_udp_tunnel m
	  end
	end
	
	def mumble2mumble rec
		unless @m2m == nil then
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
		unless @m2m != nil then
			return
		end
		return @m2m.getspeakers
	end
	
	def m2m_getframe speaker
		unless @m2m != nil then
			return
		end
		return @m2m.getframe speaker
	end
	
	def m2m_writeframe frame
		unless @m2m != nil then
			return
		end
		@m2m.produce frame
	end
	
	def m2m_getsize speaker
		unless @m2m != nil then
			return 0
		end
		return @m2m.getsize speaker
	end
	
	def source_copy_raw_audio
	  raise NoSupportedCodec unless @codec
	  unless @rsh == nil then
	    return @rsh
	  end
	  @rsh = ReceiveStreamHandler.new 'dummy.stream', @config.sample_rate, @config.sample_rate / 100, 1
	  @rsh.set_normalizer(65) 
	  return @rsh
	end
		
	def get_rsh
		return @rsh
	end
		
	def copy_raw_audio source
	  raise NoSupportedCodec unless @codec
	  on_udp_tunnel do |m|
	    @rsh.process_udp_tunnel m
	  end
	  AudioCopyStream.new(@codec, 0, @encoder, source, @conn)
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

    def setrecordfile(file)
      @recordfile=file
    end
	
	def get_imgmsg file
		to_return = ImgReader.new file
		return to_return.to_msg
	end
	
	def set_comment newcomment
		send_user_state comment: newcomment
	end

    def record(bool=true)
      unless @rsh == nil
        unless @recordfile != nil 
          send_user_state recording: false
          return
        end
        send_user_state recording: bool
        @rsh.record(bool, @recordfile)
      end
    end

    def play(normalize)
      unless @rsh == nil
        @rsh.set_normalizer(normalize) 
      end
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

    def text_user_img(user, file)
      img = ImgReader.new file
      text_user(user, img.to_msg)
    end

    def text_channel(channel, string)
      send_text_message({
        channel_id: [channel_id(channel)],
        message: string
      })
    end

    def text_channel_img(channel, file)
      img = ImgReader.new file
      text_channel(channel, img.to_msg)
    end

    def user_stats(user)
      send_user_stats session: user_session(user)
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

    private
    def spawn_thread(sym)
      Thread.new { loop { send sym } }
    end

    def read
      message = @conn.read_message
	  sym = message.class.to_s.demodulize.underscore.to_sym
	  run_callbacks sym, Hashie::Mash.new(message.to_hash)
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
        @connected = true
        @callbacks[:connected].each { |c| c.call }
      end
      on_channel_state do |message|
        if channel = channels[message.channel_id]
          channel.merge! message.to_hash
        else
          channels[message.channel_id] = Hashie::Mash.new(message.to_hash)
        end
      end
      on_channel_remove do |message|
        channels.delete(message.channel_id)
      end
      on_user_state do |message|
        if user = users[message.session]
          user.merge! message.to_hash
        else
          users[message.session] = Hashie::Mash.new(message.to_hash)
        end
      end
      on_user_remove do |message|
        users.delete(message.session)
      end
      on_codec_version do |message|
        codec_negotiation(message)
      end
    end

    def create_encoder
      @encoder = Opus::Encoder.new @config.sample_rate, @config.sample_rate / 100, 1
      @encoder.vbr_rate = @config.bitrate # CBR
      @encoder.bitrate = @config.bitrate
    end

    def version_exchange
      send_version({
        version: encode_version(1, 2, 5),
        release: "mumble-ruby #{Mumble::VERSION}",
        os: %x{uname -s}.strip,
        os_version: %x{uname -v}.strip
      })
    end

    def authenticate
      send_authenticate({
        username: @config.username,
        password: @config.password,
        opus: true
      })
    end

    def codec_negotiation(message)
      @codec = CODEC_OPUS if message.opus
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
