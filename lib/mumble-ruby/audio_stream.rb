module Mumble
  class AudioStream
    attr_reader :volume

    def initialize(type, target, encoder, file, connection, resampler)
      @type = type
      @target = target
      @encoder = encoder
      @file = File.open(file, 'rb')
      @file_stats = File.stat(file)
      @conn = connection
      @resampler = resampler
      @seq = 0
      @num_frames = 6
      @compressed_size = [@encoder.vbr_rate / 800, 127].min
      @pds = PacketDataStream.new
      @volume = 1.0

      @queue = Queue.new
      @producer = spawn_thread :produce
      @consumer = spawn_thread :consume
    end

    def volume=(volume)
      @volume = volume / 100.0
    end

    def stop
      @producer.kill
      @consumer.kill
      @file.close
    end

    private
    def change_volume(pcm_data)
      pcm_data.map { |s| (s * @volume).to_i }
    end

    def stereo_to_mono(pcm_data)
      mono_data = Array.new
      pcm_data.each_index do |i|
        if i % 2 == 0
          left = pcm_data[i].to_i
          right = pcm_data[i+1].to_i
          mono_data << (right/2 + left/2) if left && right
        end
      end
      return mono_data
    end

    def packet_header
      ((@type << 5) | @target).chr
    end

    def produce

      # Exit at the end of a file (if we're not dealing with a pipe)
        if @file_stats.file? && @file.pos == @file_stats.size
          Thread.current.exit
        end
      
      if @resampler
        frame_size = ((@resampler.input_rate * @resampler.channels * (@encoder.frame_size+2)) / @encoder.sample_rate) * 2
        data = @file.read(frame_size)
        return false unless data

        us_data = data.unpack('s*')
        us_data = stereo_to_mono us_data if @resampler.channels == 2
        us_data = change_volume us_data

        float_data = SRC::Convert.short_to_float us_data
        rs_float = @resampler.process float_data
        pcm_data = SRC::Convert.float_to_short(rs_float).pack('s*')
      else
        up_data = change_volume(@file.read(@encoder.frame_size * 2)).unpack('s*')
        pcm_data = up_data.pack('s*')
      end

      @queue << @encoder.encode(pcm_data, @compressed_size)

    end

    def consume
      
      @seq %= 1000000 # Keep sequence number reasonable for long runs

      @pds.rewind
      @seq += @num_frames
      @pds.put_int @seq

      @num_frames.times do |i|
        frame = @queue.pop
        len = frame.size
        len = len | 0x80 if i < @num_frames - 1
        @pds.append len
        @pds.append_block frame
      end

      size = @pds.size
      @pds.rewind
      data = [packet_header, @pds.get_block(size)].flatten.join
      @conn.send_udp_packet data
    end

    def spawn_thread(sym)
      Thread.new { loop { send sym } }
    end
  end
end
