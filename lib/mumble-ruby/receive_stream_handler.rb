#################################################################################
# The MIT License (MIT)                                                         #
#                                                                               #
# Copyright (c) 2014, Aaron Herting 'qwertos' <aaron@herting.cc>                #
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
  class ReceiveStreamHandler

    def initialize file, sample_rate, channels
      @file = File.open( file, 'w' )
      @pds = PacketDataStream.new

      @decoder = Hash.new do |h, k|
        h[k] = Opus::Decoder.new sample_rate, sample_rate / 100, channels
      end

      @queues = Hash.new do |h, k|
        h[k] = Queue.new
      end

      spawn_thread :write_audio
    end

    def destroy
      @decoder.each(&:destroy)
      @file.close
    end

    def process_udp_tunnel message
      @pds.rewind
      @pds.append_block message.packet[1..-1]

      @pds.rewind
      source = @pds.get_int
      seq = @pds.get_int
      len = @pds.get_int
      opus = @pds.get_block len
      opus = opus.flatten.join

      @queues[source] << @decoder[source].decode(opus)
    end

    private
    def spawn_thread sym
      Thread.new do
        loop do
          send sym
        end
      end
    end

    # TODO: Better audio stream merge with normalization
    def write_audio
      pcm = @queues.values
        .reject { |q| q.empty? }                      # Remove empty queues
        .map { |q| q.pop.unpack 's*' }                # Grab the top element of each queue and expand
        .transpose                                    # Since we now have an array of arrays, transpose the matrix
        .map { |pcms| pcms.reduce(:+) / pcms.size }   # Average together all the columns of the matrix (merge audio streams)
        .flatten                                      # Flatten the resulting 1d matrix
        .pack('s*')                                   # Pack back into PCM data
      @file.write pcm
    end

  end
end
