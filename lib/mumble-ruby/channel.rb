module Mumble
  class Channel < Model
    attribute :channel_id do
      self.data.fetch('channel_id', 0)
    end
    attribute :name
    attribute :parent_id do
      self.data['parent']
    end
    attribute :links do
      self.data.fetch('links', [])
    end

    def parent
      client.channels[parent_id]
    end

    def children
      client.channels.values.select do |channel|
        channel.parent_id == channel_id
      end
    end

    def linked_channels
      links.map do |channel_id|
        client.channels[channel_id]
      end
    end

    def users
      client.users.values.select do |user|
        user.channel_id == channel_id
      end
    end

    def join
      client.join_channel(self)
    end

    def send_text(string)
      client.text_channel(self, string)
    end

    def send_image(file)
      client.text_channel_img(self, file)
    end
  end
end
