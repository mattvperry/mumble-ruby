require 'wavefile'
require 'thread'

module Mumble
  class AudioRecorder
    include ThreadTools

    def initialize(client, sample_rate)
      @client = client
      @wav_format = WaveFile::Format.new(:mono, :pcm_16, sample_rate)
      @pds = PacketDataStream.new
      @pds_lock = Mutex.new

      @decoders = Hash.new do |h, k|
        h[k] = Opus::Decoder.new sample_rate, sample_rate / 100, 1
      end

      @queues = Hash.new do |h, k|
        h[k] = Queue.new
      end
    end

    def recording?
      @recording ||= false
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
        @decoders.values.each &:destroy
        @decoders.clear
        @queues.clear
        @file.close
        @recording = false
      end
    end

    private
    def process_udp_tunnel(message)
      @pds_lock.synchronize do
        @pds.rewind
        @pds.append_block message.packet[1..-1]

        @pds.rewind
        source = @pds.get_int
        seq = @pds.get_int
        len = @pds.get_int
        opus = @pds.get_block len

        @queues[source] << @decoders[source].decode(opus.join)
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
  end
end
