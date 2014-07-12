module Mumble
  class User < Model
    attribute :name
    attribute :session
    attribute :channel_id

    def channel
      client.channels[channel_id]
    end

    def send_text(string)
      client.text_user(self, string)
    end

    def send_image(file)
      client.text_user_img(self, file)
    end
  end
end
