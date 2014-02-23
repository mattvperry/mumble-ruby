module Mumble
  class AudioStream
    attr_reader :volume

    def initialize(type, target, encoder, file, connection)
      @type = type
      @target = target
      @encoder = encoder
      @file = File.open(file, 'rb')
      @conn = connection
      @seq = 0
      @compressed_size = 960
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
      pcm_data.unpack('s*').map { |s| s * @volume }.pack('s*')
    end

    def packet_header
      ((@type << 5) | @target).chr
    end

    def produce
      pcm_data = change_volume @file.read(@encoder.frame_size * 2)
      @queue << @encoder.encode(pcm_data, @compressed_size)
    end

    def consume
      @seq %= 1000000 # Keep sequence number reasonable for long runs

      @pds.rewind
      @seq += 1
      @pds.put_int @seq

      frame = @queue.pop
      len = frame.size
      @pds.put_int len
      @pds.append_block frame

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
