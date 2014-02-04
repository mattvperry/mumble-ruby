module Mumble
	class QueueStream < AudioStream
		def initialize(type, target, encoder, queue, connection, resampler)
			@type = type
			@target = target
			@encoder = encoder
			@input_queue = queue
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

		def stop
			@producer.kill
			@consumer.kill
		end

		private

		def produce
			rate = (@resampler) ? @resampler.input_rate : @encoder.sample_rate

			buffer = @input_queue.pop

			return unless buffer.size == rate / 2 + 100

			50.times do
				frames = buffer.shift(rate / 100 + 2).flatten
				frames = stereo_to_mono frames if @resampler.channels == 2
				frames = change_volume frames

				float_frames = SRC::Convert.short_to_float frames
				resampled = @resampler.process float_frames

				pcm_frames = SRC::Convert.float_to_short(resampled).pack("s*") 

				@queue << @encoder.encode(pcm_frames, @compressed_size)
			end
		end

		def spawn_thread(sym)
		    Thread.new { loop { send sym } }
	    end

	end
end