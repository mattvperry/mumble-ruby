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
			@opus = []
			@encoder = []
			@queue = []
			@seq = 0
			@pds = PacketDataStream.new
			@plqueue = Queue.new

			
			spawn_thread :consume
		end

		def destroy
			@opus.each do |opus|
				opus.destroy
			end
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
			header = @pds.get_next
			len = header
			if (len & 0x80) != 0x00
				last = true
			else
				last =false
			end
			opus = @pds.get_block len
			opus = opus.flatten.join
			if @opus[source] == nil then
				@opus[source] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
			end
			
			if @encoder[source] == nil then
				@encoder[source] = Opus::Encoder.new @enc_sample_rate, @enc_sample_rate / 100, 1
				@encoder[source].vbr_rate = 0 # CBR
				@encoder[source].bitrate = @enc_bitrate
			end
			
			if @queue[source] == nil then
				@queue[source] = Queue.new
			end
			raw = @opus[source].decode(opus) 
			if raw.size > 0 then
				@queue[source] << @encoder[source].encode( raw, 960 )
			end

			if last then 
				@opus[source].destroy
				@encoder[source].destroy
				@opus[source] = nil
				@encoder[source] = nil
			end
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
			@plqueue << frame
		end
		
		private

		def packet_header
			((@type << 5) | 0).chr
		end

		
		def consume 
		  frame = @plqueue.pop
		  if frame != nil then
			@seq %= 1000000 # Keep sequence number reasonable for long runs
			@pds.rewind
			@seq += 1
			@pds.put_int @seq
			len = frame.size
			@pds.put_int len
			@pds.append_block frame
			size = @pds.size
			@pds.rewind
			data = [packet_header, @pds.get_block(size)].flatten.join
			begin
				@conn.send_udp_packet data
			rescue
				puts "could not write (fatal!)"
			end
		  else
			sleep 0.002
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

