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
	class ReceiveStreamHandler

		def initialize file, sample_rate, frame_size, channels
			@file = File.open( file, 'w' )

			@pds = PacketDataStream.new
			@dec_sample_rate = sample_rate
			@dec_frame_size = frame_size
			@dec_channels = channels
			@decoder = []
			@opusq = []
			@pcm = []
			@maxlevel = 1.0
			@recording = false
			@normalizer = -1
			spawn_thread :decode_opus
		end

		def destroy
			@decoder.each do |decoder|
				decoder.destroy
			end
			@file.close
			if @recording then
				@recordfile.close;
			end
		end

		def process_udp_tunnel message
			p = message.packet

			@pds.rewind
			@pds.append_block p[1..p.size]
			
			@pds.rewind

			# if record wanted, write raw opus audio to file
			# Decoding have to do with a other program.
			# Header with explains the format is written at the beginning
			
			if @recording then
				@recordfile.write(p[1..p.size])
			end

			# if no audio prozessing wanted, don't do it :)
			if @normalizer != -1 then
				source = @pds.get_int
				seq = @pds.get_int
				len = @pds.get_int
				opus = @pds.get_block len
				opus = opus.flatten.join

				if @opusq[source] == nil then
					@opusq[source] = Queue.new
					@decoder[source] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
				end
				@opusq[source] << opus
			end
		end

		def record bool, file
			if bool then
				@recordfile = File.open( file, 'w' )
				header = []
				header << 'MumbleOpusRawStream [samplerate:<'
				header << @dec_sample_rate
				header << '> framesize:<'
				header << @dec_frame_size
				header << '> mono/stereo/more(1,2...x):<'
				header << @dec_channels
				header << '>]<BODY>repeatly: channel:int16, packetnumber:int16, datalength:int16, data[datalength]</BODY>'
				@recordfile.write(header.join)
				@recording = true
			else
				if @recordfile != nil then
					@recording = false
					@recordfile.close
				end
			end
		end

		def play normalizer
			################################################
			#-1: don't decode audio packets                #
			# 0: only merge to 32 BIT Integer              #
			# 1: normalize_audio 16BIT LE integer output   #
			#    ->minor audio issues yet (18.05.2014)     #
			# 2-32767: currently undefined                 #
			################################################
			@normalizer=normalizer
		end

		private

		def spawn_thread sym
			Thread.new do
				loop do
					# measure time 
					t1 = Time.now
					send sym
					t2 = Time.now
					# sleep a while (time for loop set to 5 ms)
					sleeptime=t1+0.005-t2
					if sleeptime > 0 then
						sleep sleeptime
					end
				end
			end
		end

		#merging to 32BIT integer
		def merge_audio pcm1s, pcm2s
			to_return = []
			pcm1s.zip( pcm2s ).each do |s1, s2|
				to_return.push ((s1.to_i + s2.to_i))
			end
			return to_return
		end

		# try to avoid exceeding 16 BIT integer limit by 2 ways:
		# first calculate a divide factor to lower maximal value
		# and get sure to get not out of boundaries
		# second push the factor slowly up every round
		# This way of normalisation produce minimal distortion by
		# maximal output-volume
		# maybe not optimized code
		def normalize_audio pcm
			to_return = []
			pcm.each do |bigpcm|
				if bigpcm.abs >= 32767 then					# if sum of streams exceed 16-bit signed integer
					@maxlevel = 32767.0 / bigpcm.abs		# calculate limiter variable for hard limit
				else
					if @maxlevel <= 0.99999 then			# else bring limiter variable slowly back
						@maxlevel += 0.000001				# to 1
					end
				end
				bigpcm = (bigpcm.to_f * @maxlevel).to_i
				if bigpcm >= 32767 then						# Hard limit if correction not work because float uncertainty
					bigpcm = 32767 
				end
				if bigpcm <= -32768 then
					bigpcm = -32768 
				end
				to_return.push (bigpcm).to_i
			end
			return to_return
		end

		# decoding of audio moved to here, because we want more control
		# when decoding time is limited sometimes. Reduces CPU-LOAD, and keep
		# low latency.
		def decode_opus
			pcm = []
			mix = nil
			@opusq.each_with_index do |opus, index|
				if !(opus == nil || opus.empty?) then
					if opus.size > 100 then
						# Drop pakets if queue grow to long. Reduce audio-lag and decoding-load, also produce audio-artefacts on dropping.
						while opus.size > 20
							drop = opus.pop
						end
					end
					# Decode Opus and enqueue audio-pcm-raw still separated per speaker
					if @pcm[index] == nil then
						@pcm[index] = @decoder[index].decode(opus.pop)
					else
						@pcm[index] = @pcm[index] + @decoder[index].decode(opus.pop)
					end
				end
			end

			# Now we have all audio decoded in separated queues, let's check fill status
			# and if enough audio there pop it and mix it together
			@pcm.each do |frame|
			  if (frame != nil) && (frame.length >= 960) then
				if mix == nil then
					mix = frame.slice!(0..959).unpack 's*'
				else
					mix = merge_audio(mix, frame.slice!(0..959).unpack('s*'))
				end
			  end
			end

			# check if mixed audio is there and do some normalisation if needed and
			# then write it out!
			if mix != nil then
				case @normalizer
					# there should come more variants...
					when 0
						@file.write (mix.pack 'l*')
					when 1
						mix = normalize_audio mix
						@file.write (mix.pack 's*')
				end
			end
		end
	end
end

