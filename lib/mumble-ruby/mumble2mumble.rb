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
require 'benchmark'
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
            @sendpds = PacketDataStream.new
            @type = type
            @conn = conn
            @compressed_size = [bitrate / 800, 127].min
            @pds_lock = Mutex.new
            @opus_decoders = Hash.new do |h, k|
                h[k] = Opus::Decoder.new sample_rate, sample_rate / 100, channels
            end
            @celt_decoders = Hash.new do |h, k|
                h[k] = Celt::Decoder.new sample_rate, sample_rate / 100, channels
            end
            @queues = Hash.new do |h, k|
                h[k] = Queue.new
            end

            @opus_encoder= Opus::Encoder.new sample_rate, sample_rate / 100, channels
            @opus_encoder.vbr_rate = 0 # CBR
            @opus_encoder.bitrate = bitrate

            @celt_encoder= Celt::Encoder.new sample_rate, sample_rate / 100, channels
            @celt_encoder.vbr_rate = bitrate
            @celt_encoder.prediction_request = 0

            @rawaudio = ''
            
            @seq = 0
            @plqueue = Queue.new

            spawn_threads :consume
        end


        def process_udp_tunnel message
            @pds_lock.synchronize do
                @pds.rewind
                @pds.append_block message.packet#[1..-1]

                @pds.rewind
                packet_type = @pds.get_next
                source = @pds.get_int
                seq = @pds.get_int
                if @queues[source].size <= 200 then
                    case (packet_type >> 5 )
                    when CODEC_ALPHA
                        len = @pds.get_next 
                        audio = @pds.get_block ( len & 0x7f )
                        @queues[source] << @celt_decoders[source].decode(audio.join) 
                        while (len & 0x80) != 0
                            len = @pds.get_next 
                            audio = @pds.get_block ( len & 0x7f )
                            @queues[source] << @celt_decoders[source].decode(audio.join) if len & 0x7f !=0
                        end
                    when CODEC_BETA
                        len = @pds.get_next 
                        audio = @pds.get_block ( len & 0x7f )
                        @queues[source] << @celt_decoders[source].decode(audio.join) 
                        while (len & 0x80) != 0
                            len = @pds.get_next 
                            audio += @pds.get_block ( len & 0x7f )
                            @queues[source] << @celt_decoders[source].decode(audio.join) 
                        end
                    when CODEC_OPUS
                        len = @pds.get_int 
                        audio = @pds.get_block len
                        @queues[source] << @opus_decoders[source].decode(audio.join)
                    when CODEC_SPEEX
                        #puts "SPEEX CODEC"
                    when 1
                        #puts "PING PACKET"
                    when 4..7
                        #puts "should be unused!"
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
        end

        def produce frame
            @rawaudio += frame
        end
        
        def set_codec type
            @type = type
        end

        def init_encoder type
            @type = type
        end

        private

        def consume 
            num_frames = 0
            case @type
                when CODEC_OPUS
                    packet_header = ((CODEC_OPUS << 5) | 0).chr
                    while @rawaudio.size >= ( @opus_encoder.frame_size * 2 )
                        num_frames += 1
                        part = @rawaudio.slice!( 0, (@opus_encoder.frame_size * 2 ) )
                        @plqueue << @opus_encoder.encode(part, COMPRESSED_SIZE)
                    end
                when CODEC_ALPHA
                    packet_header = ((CODEC_ALPHA << 5) | 0).chr
                    while @rawaudio.size >= ( @celt_encoder.frame_size * 2 )
                        num_frames =+1
                        part = @rawaudio.slice!( 0, (@celt_encoder.frame_size * 2 ) )
                        @plqueue << @celt_encoder.encode(part, @compressed_size )
                    end
                when CODEC_BETA
                    packet_header = ((CODEC_BETA << 5) | 0).chr
                    while @rawaudio.size >= ( @celt_encoder.frame_size * 2 )
                        num_frames =+1
                        part = @rawaudio.slice!( 0, (@celt_encoder.frame_size * 2 ) )
                        @plqueue << @celt_encoder.encode(part, @compressed_size )
                    end
            end

            if @plqueue.size > 0 then
                @sendpds.rewind
                @seq += 1
                @sendpds.put_int @seq
                frame = @plqueue.pop
                len = frame.size
                @sendpds.append len
                @sendpds.append_block frame
                size = @sendpds.size
                @sendpds.rewind
                data = [packet_header, @sendpds.get_block(size)].flatten.join
                begin
                    @conn.send_udp_packet data
                rescue
                    puts "could not write (fatal!) "
                end
            else
                sleep 0.002
            end
        end
    end
end

