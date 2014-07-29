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
        include ThreadTools
        COMPRESSED_SIZE = 960
        CODEC_ALPHA = 0
        CODEC_SPEEX = 2
        CODEC_BETA = 3
        CODEC_OPUS = 4

        def initialize type, conn, sample_rate, frame_size, channels, bitrate

            @pds = PacketDataStream.new
            @dec_sample_rate = sample_rate
            @dec_frame_size = frame_size
            @dec_channels = channels
            @type = type
            @conn = conn
            @enc_sample_rate = sample_rate
            @enc_frame_size = frame_size
            @enc_bitrate = bitrate
            @compressed_size = [bitrate / 800, 127].min
            @pds_lock = Mutex.new
            @opus_decoders = Hash.new do |h, k|
                h[k] = Opus::Decoder.new sample_rate, sample_rate / 100, 1
            end
            @celt_decoders = Hash.new do |h, k|
               h[k] = Celt::Decoder.new sample_rate, sample_rate / 100, 1
            end
            @queues = Hash.new do |h, k|
                h[k] = Queue.new
            end

            @encoder = nil
            init_encoder type

            @seq = 0
            @pds = PacketDataStream.new
            @plqueue = Queue.new

            spawn_thread :consume
        end


        def process_udp_tunnel message
            @pds_lock.synchronize do
                @pds.rewind
                @pds.append_block message.packet#[1..-1]

                @pds.rewind
                packet_type = @pds.get_next
                source = @pds.get_int
                seq = @pds.get_int
                len = @pds.get_next
                audio = @pds.get_block ( len & 0x7f )
                #@decoders[source].inspect
                if @queues[source].size <= 200 then
                    case (packet_type >> 5 )
                    when CODEC_ALPHA
                        @queues[source] << @celt_decoders[source].decode(audio.join) 
                        puts "CELT input from " + source.to_s
                    when CODEC_BETA
                        puts "CELT-BETA CODEC"
                    when CODEC_OPUS
                        @queues[source] << @opus_decoders[source].decode(audio.join)
                        puts "OPUS input from " + source.to_s 
                    when CODEC_SPEEX
                        puts "SPEEX CODEC"
                    when 1
                        puts "PING PACKET"
                    when 4..7
                        puts "should be unused!"
                    end
                end
            end
        end

        def getspeakers
            return @queues.keys
        end

        def	getframe speaker
            return @queues[speaker].pop
        end

        def getsize speaker
            return @queues[speaker].size
        endC

        def produce frame
            # Ready to reencode
            #@plqueue << @encoder.encode( frame, @compressed_size )
            if @type == 4 then
                @plqueue << @encoder.encode(frame, COMPRESSED_SIZE)
            else
                while frame.size >=1 do 
                    part = frame.slice!(0..@encoder.frame_size*2)
                    @plqueue << @encoder.encode(part, @compressed_size )
                end
            end
        end

        def init_encoder type
            @type = type
            if @encoder != nil then
                @encoder.destroy
            end
            if @type == 4 then
                @encoder= Opus::Encoder.new @enc_sample_rate, @enc_sample_rate / 100, 1
                @encoder.vbr_rate = 0 # CBR
                @encoder.bitrate = @enc_bitrate
            else
                @encoder= Celt::Encoder.new @enc_sample_rate, @enc_sample_rate / 100, 1
                @encoder.vbr_rate = @enc_bitrate
                @encoder.prediction_request = 0
            end
        end

        private

        def packet_header
            ((@type << 5) | 0).chr
        end

        def consume 
            @pds.rewind
            @seq += 1
            @pds.put_int @seq
            frame = @plqueue.pop
            len = frame.size
            @pds.append len
            @pds.append_block frame
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

