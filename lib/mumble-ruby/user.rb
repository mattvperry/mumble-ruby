module Mumble
  class User < Model
    attribute :session
    attribute :user_id
    attribute :actor
    attribute :name
    attribute :channel_id
    attribute :hash
    attribute :comment
    attribute :mute
    attribute :deaf
    attribute :self_mute
    attribute :self_deaf

    def current_channel
      client.channels[channel_id]
    end

    def send_text(string)
      client.text_user(self, string)
    end

    def send_image(file)
      client.text_user_img(self, file)
    end

    def mute(bool=true)
      client.send_user_state self_mute: bool
    end

    def deafen(bool=true)
      client.send_user_state self_deaf: bool
    end

    def muted?
      !!data['suppress'] || !!data['mute'] || !!self_mute
    end

    def deafened?
      !!data['deaf'] || !!self_deaf
    end

    def register
      client.send_user_state(session: session, user_id: 0)
    end

    def stats
      client.send_user_stats session: session
    end
  end
end
