require 'wavefile'

module Mumble
  class AudioPlayer
    include ThreadTools
    COMPRESSED_SIZE = 48

    def initialize(type, connection, sample_rate, bitrate)
      @packet_header = (type << 5).chr
      @conn = connection
      @pds = PacketDataStream.new
      @queue = SizedQueue.new 100
      @wav_format = WaveFile::Format.new :mono, :pcm_16, sample_rate
      @type = type
      @bitrate = bitrate
      @sample_rate = sample_rate
      @framesize = COMPRESSED_SIZE * 10    
      create_encoder sample_rate, bitrate
      PortAudio.init
    end

    def set_codec(type)
      @type = type
      @packet_header = (type << 5).chr
      create_encoder @sample_rate, @bitrate
    end

    def destroy
      kill_threads
    end

    def volume
      @volume ||= 100
    end

    def volume=(volume)
      @volume = volume
    end

    def playing?
      @playing ||= false
    end

    def play_file(file)
      unless playing?
        @file = WaveFile::Reader.new(file, @wav_format)
        Thread.new { bounded_produce }
        @playing = true
      end
    end

    def stream_named_pipe(pipe)
      unless playing?
        @file = File.open(pipe, 'rb')
        spawn_threads :produce
        @playing = true
      end
    end

    def stream_portaudio
      begin
        require 'ruby-portaudio'
        unless playing?
          @portaudio = PortAudio::Stream.open( :sample_rate => 48000, :frames => 8192, :input => { :device => PortAudio::Device.default_input, :channels => 1, :sample_format => :int16, :suggested_latency => 0.05 })
          @audiobuffer = PortAudio::SampleBuffer.new( :format => :float32, :channels => 1, :frames => @framesize)
          @portaudio.start
          spawn_threads :portaudio
          @playing = true
        end
        true
      rescue
        # no portaudio installed - no streaming possible
        false
      end
    end

    def stop
      if playing?
        kill_threads
        @encoder.reset
        @file.close unless @file.closed?
        @portaudio.stop unless @portaudio.stopped?
        @playing = false
      end
    end

    def set_bitrate bitrate
      if !(@type == CODEC_ALPHA || @type == CODEC_BETA)
        begin
          @encoder.bitrate = bitrate
          @bitrate = bitrate
        rescue
        end
      end
    end

    def get_bitrate
      @bitrate
    end

    def set_framelength miliseconds
      case miliseconds
      when 1..4
        framelength = 2.5
      when 5..14
        framelength = 10
      when 15..30
        framelength = 20
      when 31..45
        framelength = 40
      else
        framelength = 60
      end
      @framesize= COMPRESSED_SIZE * framelength
      begin
        @encoder.set_frame_size @framesize
        @audiobuffer = PortAudio::SampleBuffer.new( :format => :float32, :channels => 1, :frames => @framesize) if !@portaudio.stopped?
      rescue
      end
    end

    def get_frame_length
      begin
        (@encoder.frame_size / COMPRESSED_SIZE).to_i
      rescue
        puts $1
      end
    end

    def get_framelength
      @framesize / COMPRESSED_SIZE
    end
    private
    def create_encoder(sample_rate, bitrate)
      kill_threads
      @encoder.destroy if @encoder != nil 

      if @type == CODEC_ALPHA || @type == CODEC_BETA
        @encoder = Celt::Encoder.new sample_rate, sample_rate / 100, 1, [bitrate / 800, 127].min
        @encoder.vbr_rate = bitrate
        @encoder.prediction_request = 0
      else
        @encoder = Opus::Encoder.new sample_rate, @framesize, 1, 7200
        @encoder.bitrate = bitrate
        @encoder.opus_set_signal Opus::Constants::OPUS_SIGNAL_MUSIC # alternative OPUS_SIGNAL_VOICE  but then constrainded vbr not work.
        begin
          @encoder.opus_set_vbr 1
          @encoder.opus_set_vbr_constraint 1        # 1 constrainted VBR , 0 unconstrainded VBR
          @encoder.opus_set_packet_loss_perc 10     # calculate with 10 percent packet loss 
          @encoder.opus_set_dtx 1
        rescue
          puts "[Warning] Some OPUS functions not aviable, use dafoxia's opus-ruby!"
          puts $!
        end
        begin
          @encoder.packet_loss_perc= 10
        rescue
          puts "[Warning] Packet Loss Resistance could not setted"
        end
      end
    end

    # TODO: call native functions
    def change_volume(pcm_data)
      pcm_data.unpack('s*').map { |s| s * (volume / 100.0) }.pack('s*')
    end

    def bounded_produce
      @file.each_buffer(@encoder.frame_size) do |buffer|
        encode_sample buffer.samples.pack('s*')
        consume
      end

      stop
    end

    def produce
      encode_sample @file.read(@encoder.frame_size*2)
      consume
    end

    def portaudio
      begin
        @portaudio.read(@audiobuffer)
        @queue << @encoder.encode_ptr(@audiobuffer.to_ptr)
        consume
      rescue
        sleep 0.2
      end
    end

    def encode_sample(sample)
      if volume < 100
        @queue << @encoder.encode(change_volume(sample))
      else
        @queue << @encoder.encode(sample)
      end
    end

    def consume
      @seq ||= 0
      @seq %= 1000000 # Keep sequence number reasonable for long runs
      @pds.rewind
      @seq += 1
      @pds.put_int @seq
      frame = @queue.pop
      @pds.put_int frame.size
      @pds.append_block frame

      size = @pds.size
      @pds.rewind
      data = [@packet_header, @pds.get_block(size)].flatten.join
      @conn.send_udp_packet data
    end
  end
end
