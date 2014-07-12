module Mumble
  class Channel < Model
    attribute :channel_id
    attribute :name
    attribute :parent_id do
      self.data['parent']
    end

    def parent
      client.channels[parent_id]
    end

    def children
      client.channels.select do |channel|
        channel.parent_id == channel_id
      end
    end
  end
end
