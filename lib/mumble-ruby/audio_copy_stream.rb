
#################################################################################
# The MIT License (MIT)                                                         #
#                                                                               #
# Copyright (c) 2014, Reinhard Bramel 'dafoxia' <dafoxia@mail.austria.com>      #
#                     Matthew Perry (because it's based on audio_stream.rb)     #
#                                                                               #
# Permission is hereby granted, free of charge, to any person obtaining a copy  #
# of this software and associated documentation files (the "Software"), to deal #
# in the Software without restriction, including without limitation the rights  #
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell     #
# copies of the Software, and to permit persons to whom the Software is         #
# furnished to do so, subject to the following conditions:                      #
#                                                                               #
# The above copyright notice and this permission notice shall be included in    #
# all copies or substantial portions of the Software.                           #
#                                                                               #
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR    #
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,      #
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE   #
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER        #
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, #
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN     #
# THE SOFTWARE.                                                                 #
#################################################################################

module Mumble
  class AudioCopyStream
    attr_reader :volume

    def initialize(type, target, encoder, copysource, connection)
	
      @type = type
      @target = target
      @encoder = encoder
      @conn = connection
      @seq = 0
      @compressed_size = 960
      @pds = PacketDataStream.new
	  @copysource = copysource
      @queue = Queue.new
      @producer = spawn_thread :produce
      @consumer = spawn_thread :consume
    end


    def stop
      @producer.kill
      @consumer.kill
    end

    private
 
    def packet_header
      ((@type << 5) | @target).chr
    end

    def produce
	  pcm_data = @copysource.get_pcm ( @encoder.frame_size * 2 )	
	  if pcm_data == nil then
		until pcm_data != nil
		  sleep(0.05)
		  pcm_data = @copysource.get_pcm ( @encoder.frame_size * 2 )
		end
	  end
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
