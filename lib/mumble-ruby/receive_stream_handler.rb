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


	# Size of JitterBuffer is controlled from _outside_ the class!
	# output data are sorted by the key given data on input in
	# buffer on the way. Greater Buffer-Size means better de-jitter 
	# but also longer latency.
	
	class JitterBuffer
		
		def initialize 
			@data = {}
			@lastkey = 0
			@count = 0
			@datainfo = 0
		end

		def add key, data
			@data[key] = data
		end
	
		def pop
			if !( @data.size == 0 ) then
				first = @data.keys.sort.reverse.pop
				if ( first - 1 ) != @lastkey then
					@count = ( first - 1 - @lastkey )
				end
				@lastkey = first
				return @data.delete(first)
			else
				@count = -1
				return nil
			end
		end

		def missed_packets?
			if @count != 0 then
				return true
			else
				return false
			end
		end
		
		def	datainfo
			return @datainfo
		end
		
		def size
			return @data.size
		end
		
		def empty? 
			if @data.size == 0 then
				return true
			else
				return false
			end
		end
	
		alias :<< :add 
		alias :push :add 
		alias :enq :add 
		alias :deq :pop
		alias :shift :pop
		alias :clear :initialize
		alias :length :size
	end

	class ReceiveStreamHandler

		def initialize file, sample_rate, frame_size, channels
			if file == "-" then
				if STDOUT.tty? then
					# "-" seems to be a strange named fifo file
					# maybe the pipe is broken and we write to
					# local directory in a file named -
					@file = File.open( file, 'w' )
				else
					@file = STDOUT
				end
			else
				if file != "dummy.stream" then
					@file = File.open( file, 'w' )
				end
			end

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
			@pcmbuffer = ''
			@pcmbuffersize = 0
			@jitterbuffersize =25

			spawn_thread :decode_opus
			spawn_thread :mixandplay
		end

		def destroy
			@decoder.each do |decoder|
				decoder.destroy
			end
			if @file != nil then
				@file.close
			end
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
				header = @pds.get_int
				len = header
				opus = @pds.get_block len
				opus = opus.flatten.join

				if @opusq[source] == nil then
					@opusq[source] = JitterBuffer.new 
				end
				
				# Don't create Decoder here. It's early enough before decode in decoder run
				#if @decoder[source] == nil then
				#	@decoder[source] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
				#end
				@opusq[source].add seq, opus
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
		
		def get_recording_state
			return @recording
		end

		def set_normalizer normalizer
			################################################
			#-1: don't decode audio packets                #
			# 0: only merge to 32 BIT Integer              #
			# 1: normalize_audio 16BIT LE integer output   #
			#    ->minor audio issues yet (18.05.2014)     #
			# 2: only hard limit (useful results on low    #
			#     simultaneous speakers                    #
			#65: 1 and store in pcmbuffer don't write out! # 
			# others:  currently undefined                 #
			################################################
			@normalizer=normalizer
		end
		
		def get_normalizer
			return @normalizer
		end

		def set_pcm_buffer_size size
			if size >= 0 then
				@pcmbuffersize = size
			end
		end
		
		def get_pcm size
			if @pcmbuffer.size >= size then
				return @pcmbuffer.slice!(0..(size-1))
			else
				return nil
			end
		end
		
		def	get_pcm_buffer_size
			return @pcmbuffersize
		end
		
		def get_pcm_fill
			if @pcmbuffersize > 0 then
				return ( ( @pcmbuffer.size * 100 ) / @pcmbuffersize )
			else
				return	@pcmbuffer.size
			end
		end
		
		def set_jitterbuffer size
			if size >= 2 then
				@jitterbuffersize = size
			end
		end
		
		def get_jitterbuffer
			to_return @jitterbuffersize
		end
		
		private

		def spawn_thread sym
			Thread.new do
				loop do
					send sym
				end
			end
		end

		#merging to 32BIT integer
		def merge_audio pcm1s, pcm2s
			to_return = []
			if pcm1s.length != pcm2s.length then
			end
			pcm1s.zip( pcm2s ).each do |s1, s2|
				to_return.push ((s1 + s2))
			end
			return to_return
		end

		# try to avoid exceeding 16 BIT integer limit by 2 ways:
		# first calculate a divide factor to lower maximal value
		# and get sure to get not out of boundaries
		# second push the factor slowly up every round
		# This way of normalisation produce minimal distortion by
		# maximal output-volume
		# maybe not optimized code, sounds in most cases better 
		# then hard_limit_audio
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

		# Hard limit audio works good if not to many users 
		# speak simultaneous and their audio loudness is not 
		# to heavy at their maximum loudness
		# This normalizer cuts simply 'this part of the iceberg's
		# which reach out of the water line' :D
		# sounds terrible when iceberg's are huge and often
		def hard_limit_audio pcm
			to_return = []
			pcm.each do |bigpcm|
				if bigpcm >= 32767 then						
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
			maxqueue = 0		#resetqueuelenghtcounter
			@opusq.each_with_index do	|opus, speaker|
				if opus != nil then
					if opus.length > maxqueue then
						maxqueue = opus.length
					end
					# Decode Opus as long queue length not 'explode'
					while ( opus.size >= @jitterbuffersize ) && ( opus.size <= ( @jitterbuffersize * 3 ) )
						opuspacket = opus.pop
						# create decoder if not exists already
						if	@decoder[speaker]==nil then
							@decoder[speaker] = Opus::Decoder.new @dec_sample_rate, @dec_frame_size, @dec_channels
						end
						# when gaps in stream occur say it opus-decoder (minimize suspect sounds)
						if opus.missed_packets? then
							@decoder[speaker].decode_missed
						end
						# decode packet and add it in pcm-stream-string
						pcm = @decoder[speaker].decode(opuspacket)
						if @pcm[speaker] == nil then
							@pcm[speaker] = pcm
						else
							@pcm[speaker] = @pcm[speaker] + pcm
						end
					end
					if opus.size > ( @jitterbuffersize * 3 ) then
						# Drop pakets if queue grow to long. Reduce audio-lag and decoding-load, produces audio-artefacts on dropping!
						while opus.size > ( @jitterbuffersize * 2 )
							opus.pop
						end
						puts "WARNING ! Packet drop! Overfill primary jitter buffer"
					end
				end
			end
			
			# lose handbrake when opus-queue fills
			if ( maxqueue <= ( @jitterbuffersize * 2 ) ) then
				handbrake=  0.05 - ( maxqueue / ( @jitterbuffersize * 40 ).to_f )
				if handbrake >= 0 then 
					sleep(handbrake)
				end
			end
			
		end
		
		def mixandplay
			# Let's check fill status and if enough audio there pop it and mix it together
			maxqueue = 0
			@pcm.each do |frame|
				if (frame != nil) && (frame.length > maxqueue) then
					maxqueue = frame.length
				end
			end
			
			# lose handbrake when pcm-buffer increase
			if ( maxqueue <= 96000 ) then
				handbrake=  0.05 - ( maxqueue / 960000.0 )
				if handbrake >= 0 then 
					sleep(handbrake)
				end
			end
			
			mix = nil
			@pcm.each_with_index do |frame, speaker|
				if (frame != nil) && (frame.length >= 1920) then
					pcmaudio = frame.slice!(0..959)
					if mix == nil then
						mix = pcmaudio.unpack('s*')
					else
						mix = merge_audio(mix, pcmaudio.unpack('s*'))
					end
				end
			end
			
			# check if mixed audio is there and do some normalisation if needed and
			# then write it out!
			if (mix != nil) then
				case @normalizer
					# there should come more variants...
					when 0
						@file.write (mix.pack 'l*')
					when 1
						mix = normalize_audio mix
						@file.write (mix.pack 's*')
					when 2
						mix = hard_limit_audio mix
						@file.write (mix.pack 's*')
					when 65
						mix = normalize_audio mix
						@pcmbuffer = @pcmbuffer + mix.pack('s*')
				end
			end
		end
	end
end

