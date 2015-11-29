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
      @framesize = COMPRESSED_SIZE * 60    #60ms Audioframes by default (for music realtime is not critical)
      create_encoder sample_rate, bitrate
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
        spawn_threads :produce, :consume
        @playing = true
      end
    end

    def stop
      if playing?
        kill_threads
        @encoder.reset
        @file.close unless @file.closed?
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
        @encoder.vbr_rate = 0 # CBR
        @encoder.bitrate = bitrate
        @encoder.signal = Opus::Constants::OPUS_SIGNAL_MUSIC
      end
      if playing? then  
        spawn_threads :produce, :consume 
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
      encode_sample @file.read(@encoder.frame_size * 2)
    end

    def encode_sample(sample)
      if volume < 100
        pcm_data = change_volume sample
      else
        pcm_data = sample
      end
      @queue << @encoder.encode(pcm_data)
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
