require 'wavefile'
require 'thread'
require 'ruby-portaudio'

module Mumble
  class AudioRecorder
    include ThreadTools
    CODEC_ALPHA = 0
    CODEC_BETA = 3
    CODEC_OPUS = 4

    def initialize(client, sample_rate)
      @client = client
      @wav_format = WaveFile::Format.new(:mono, :pcm_16, sample_rate)
      @pds = PacketDataStream.new
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
    end

    def recording?
      @recording ||= false
    end

    def stream_portaudio
      unless recording?
        PortAudio.init
        @portaudio = PortAudio::Stream.open( :sample_rate => 48000, :frames => 8192, :output => { :device => PortAudio::Device.default_output, :channels => 1, :sample_format => :int16, :suggested_latency => 0.25 })
        @audiobuffer = PortAudio::SampleBuffer.new(:format   => :int16, :channels => 1, :frames => 8192)
        @portaudio.start
        @callback = @client.on_udp_tunnel { |msg| process_udp_tunnel msg }
        spawn_thread :portaudio
        @recording = true
      end
    end

    def start(file)
      unless recording?
        @file = WaveFile::Writer.new(file, @wav_format)
        @callback = @client.on_udp_tunnel { |msg| process_udp_tunnel msg }
        spawn_thread :write_audio
        @recording = true
      end
    end

    def stop
      if recording?
        @client.remove_callback :udp_tunnel, @callback
        kill_threads
        @opus_decoders.values.each &:destroy
        @opus_decoders.clear
        @queues.clear
        @file.close
        @recording = false
      end
    end

    private
    def process_udp_tunnel(message)
      @pds_lock.synchronize do
        @pds.rewind
        @pds.append_block message.packet#[1..-1]        # we need packet type info

        @pds.rewind
        packet_type = @pds.get_next
        source = @pds.get_int
        seq = @pds.get_int
        case ( packet_type >> 5 )
          when CODEC_ALPHA
            len = @pds.get_next
            alpha = @pds.get_block ( len & 0x7f )
            @queues[source] << @celt_decoders[source].decode(alpha.join)
            while ( len  0x80 ) != 0
              len = @pds.get_next
              alpha = @pds.get_block ( len & 0x7f )
              @queues[source] << @celt_decoders[source].decode(alpha.join)
            end
          when CODEC_BETA
            len = @pds.get_next
            beta = @pds.get_block ( len & 0x7f )
            @queues[source] << @celt_decoders[source].decode(beta.join)
            while ( len  0x80 ) != 0
              len = @pds.get_next
              beta = @pds.get_block ( len & 0x7f )
              @queues[source] << @celt_decoders[source].decode(beta.join)
            end
          when CODEC_OPUS
            len = @pds.get_int
            opus = @pds.get_block ( len & 0x1FFF )
            @queues[source] << @opus_decoders[source].decode(opus.join)
            @opus_decoders[source].reset if ( len & 0x2000 ) == 0x2000
        end
      end
    end

    # TODO: Better audio stream merge with normalization
    def write_audio
      pcms = @queues.values
        .reject { |q| q.empty? }                      # Remove empty queues
        .map { |q| q.pop.unpack 's*' }                # Grab the top element of each queue and expand

      head, *tail = pcms
      if head
        samples = head.zip(*tail)
          .map { |pcms| pcms.reduce(:+) / pcms.size }   # Average together all the columns of the matrix (merge audio streams)
          .flatten                                      # Flatten the resulting 1d matrix
        @file.write WaveFile::Buffer.new(samples, @wav_format)
      end
    end

    def portaudio
      pcms = @queues.values
        .reject { |q| q.empty? }                      # Remove empty queues
        .map { |q| q.pop.unpack 's*' }                # Grab the top element of each queue and expand
      head, *tail = pcms
      if head
        samples = head.zip(*tail)
          .map { |pcms| pcms.reduce(:+) / pcms.size }   # Average together all the columns of the matrix (merge audio streams)
          .flatten                                      # Flatten the resulting 1d matrix
        @audiobuffer = PortAudio::SampleBuffer.new(:format   => :int16, :channels => 1, :frames => send.size / 2 +1)
        @audiobuffer.add(sample.pack 's*')
        begin
          @portaudio << @audiobuffer
        rescue
        end
      end
    end
  end
end
