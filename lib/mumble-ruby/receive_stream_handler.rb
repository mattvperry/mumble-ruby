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

		def initialize file, sample_rate, frame_size, channels
			@file = File.open( file, 'w' )

			@pds = PacketDataStream.new
			#@decoder = Opus::Decoder.new sample_rate, frame_size, channels  //Don't create yet, we have to create for every stream!
			@dec_sample_rate = sample_rate
			@dec_frame_size = frame_size
			@dec_channels = channels
			@decoder = []
			@queues = []
			spawn_thread :play_audio
		end

		def destroy
			@decoder.destroy
			@file.close
		end

		def process_udp_tunnel message
			p = message.packet

			@pds.rewind
			@pds.append_block p[1..p.size]
			
			@pds.rewind
			source = @pds.get_int
			seq = @pds.get_int
			len = @pds.get_int
			opus = @pds.get_block len
			opus = opus.flatten.join

			if @queues[source] == nil then
				@queues[source] = Queue.new
				@decoder[source] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
			end

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

		def merge_audio pcm1, pcm2
			pcm1_short = pcm1.unpack 's*'
			pcm2_short = pcm2.unpack 's*'
			to_return = []

			pcm1_short.zip( pcm2_short ).each do |s1, s2|
				to_return.push(( s1 + s2 ) / 2 )
				# TODO: need better audio merging with normalizing
			end

			return to_return.pack 's*'
		end

		def play_audio
			pcm = nil
			
			@queues.each do |queue|
				if queue == nil || queue.empty? then
					next
				end
				if pcm == nil then
					pcm = queue.pop
				else
					pcm = merge_audio pcm, queue.pop
				end
			end
			
			@file.write pcm
		end

	end
end

