require 'wavefile'

module Mumble
  class AudioPlayer
    include ThreadTools
    COMPRESSED_SIZE = 960

    def initialize(type, connection, sample_rate, bitrate)
      @packet_header = (type << 5).chr
      @conn = connection
      @pds = PacketDataStream.new
      @queue = Queue.new
      @wav_format = WaveFile::Format.new :mono, :pcm_16, sample_rate

      create_encoder sample_rate, bitrate
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

    private
    def create_encoder(sample_rate, bitrate)
      @encoder = Opus::Encoder.new sample_rate, sample_rate / 100, 1
      @encoder.vbr_rate = 0 # CBR
      @encoder.bitrate = bitrate
    end

    def change_volume(pcm_data)
      pcm_data.unpack('s*').map { |s| s * (volume / 100.0) }.pack('s*')
    end

    def bounded_produce
      frame_count = 0
      start_time = Time.now.to_f
      @file.each_buffer(@encoder.frame_size) do |buffer|
        encode_sample buffer.samples.pack('s*')
        consume
        frame_count += 1
        wait_time = start_time - Time.now.to_f + frame_count * 0.01
        sleep(wait_time) if wait_time > 0
      end

      stop
    end

    def produce
      encode_sample @file.read(@encoder.frame_size * 2)
    end

    def encode_sample(sample)
      pcm_data = change_volume sample
      @queue << @encoder.encode(pcm_data, COMPRESSED_SIZE)
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
