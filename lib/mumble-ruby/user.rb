module Mumble
  class User < Model
    attribute :session
    attribute :actor
    attribute :name
    attribute :channel_id
    attribute :hash
    attribute :comment
    attribute :mute
    attribute :deaf
    attribute :self_mute
    attribute :self_deaf

    def channel
      client.channels[channel_id]
    end

    def send_text(string)
      client.text_user(self, string)
    end

    def send_image(file)
      client.text_user_img(self, file)
    end

    def muted?
      !!mute || !!self_mute
    end

    def deafened?
      !!deaf || !!self_deaf
    end
  end
end
