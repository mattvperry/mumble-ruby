#################################################################################
# The MIT License (MIT)                                                         #
#                                                                               #
# Copyright (c) 2014, Aaron Herting 'qwertos' <aaron@herting.cc>,               #
#                     Reinhard Bramel 'dafoxia' <dafoxia@mail.austria.com>      #
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

	class Mumble2Mumble

		def initialize type, conn, sample_rate, frame_size, channels, bitrate

			@pds = PacketDataStream.new
			@dec_sample_rate = sample_rate
			@dec_frame_size = frame_size
			@dec_channels = channels
			@type = type
			@conn = conn
			@enc_sample_rate = sample_rate
			@enc_frame_size = frame_size
			@enc_bitrate =bitrate
			
			@decoder = []
			@encoder = nil
			init_encoder type
			@queue = []
			
			@num_frames = 1
			@seq = 0
			@pds = PacketDataStream.new
			@plqueue = Queue.new

			spawn_thread :consume
		end

		def destroy
			@decoder.destroy
			@encoder.each do |encoder|
				encoder.destroy
			end
		end

		def process_udp_tunnel message
			p = message.packet

			@pds.rewind
			@pds.append_block p[1..p.size]
			
			@pds.rewind

			source = @pds.get_int
			seq = @pds.get_int
			header = @pds.get_int
			len = header
			if (len & 0x80) != 0x00
				last = true
			else
				last =false
			end
			audio = @pds.get_block len
			audio = audio.flatten.join

			if @queue[source] == nil then
				@queue[source] = Queue.new
			end

			if @decoder[source] == nil then
					@decoder[source] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
					@num_frames=1
			end
	
			# only decode, encoding is done before sending
			@queue[source] << @decoder[source].decode(audio)
		end

		def getspeakers
			speakers = []
			@queue.each_with_index do |q, i|
				if (q != nil) && ( q.size >= 1 ) then
					speakers << i
				end
			end
			return speakers
		end

		def	getframe speaker
			if ( @queue[speaker] != nil ) && ( @queue[speaker].size >= 1 ) then
				return @queue[speaker].pop
			else
				return nil
			end
		end

		def getsize speaker
			if  @queue[speaker] != nil then
				return @queue[speaker].size
			else
				return 0
			end
		end
		
		def produce frame
			# Ready to reencode
			@plqueue << @encoder.encode( frame, @enc_frame_size )
		end
		
		def init_encoder type
			@type = type
			if @encoder != nil then
				@encoder.destroy
			end
			@encoder= Opus::Encoder.new @enc_sample_rate, @enc_sample_rate / 100, 1
			@encoder.vbr_rate = 0 # CBR
			@encoder.bitrate = @enc_bitrate
			@num_frames=1
		end
		


		private


		def packet_header
			((@type << 5) | 0).chr
		end

		def consume 
			@pds.rewind
			@seq += @num_frames
			@pds.put_int @seq
			@num_frames.times do |i|
				frame = @plqueue.pop
				len = frame.size
				len = len | 0x80 if i < @num_frames -1
				@pds.append len
				@pds.append_block frame
			end

			size = @pds.size
			@pds.rewind
			data = [packet_header, @pds.get_block(size)].flatten.join
			begin
				@conn.send_udp_packet data
			rescue
				puts "could not write (fatal!) "
			end
		end

		def spawn_thread sym
			Thread.new do
				loop do
					send sym
				end
			end
		end
		
	end
end

