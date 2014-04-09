module Mumble
	class ReceiveStreamHandler

		def initialize file, sample_rate, frame_size, channels
			@file = File.open( file, 'w' )

			@pds = PacketDataStream.new
			@decoder = Opus::Decoder.new sample_rate, frame_size, channels
			@queues = []
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
			end

			@queue[source] << @decoder.decode(opus)
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

