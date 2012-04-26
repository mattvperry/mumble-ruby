module Mumble
  class AudioStream
    def initialize(type, target, encoder, file, connection)
      @type = type
      @target = target
      @encoder = encoder
      @file = File.open(file, 'rb')
      @conn = connection
      @seq = 0
      @num_frames = 6
      @compressed_size = [@encoder.vbr_rate / 800, 127].min
      @pds = PacketDataStream.new

      @queue = Queue.new
      @producer = spawn_thread :produce
      @consumer = spawn_thread :consume
    end

    def stop
      @producer.kill
      @consumer.kill
      @file.close
    end

    private
    def packet_header
      ((@type << 5) | @target).chr
    end

    def produce
      pcm_data = @file.read(@encoder.frame_size * 2)
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
