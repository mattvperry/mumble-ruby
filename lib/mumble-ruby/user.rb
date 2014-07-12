module Mumble
  class User < Model
    attribute :name
    attribute :session
    attribute :channel_id

    def channel
      client.channels[channel_id]
    end
  end
end
