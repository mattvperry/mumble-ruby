require 'forwardable'

module Mumble
  class Model
    extend ::Forwardable

    class << self
      def attribute(name, &block)
        attributes << name
        define_method(name) do
          if block_given?
            self.instance_eval(&block)
          else
            @data[name.to_s]
          end
        end
      end

      def attributes
        @attributes ||= []
      end
    end

    def initialize(client, data)
      @client = client
      @data   = data
    end

    def update(data)
      @data.merge!(data)
    end

    def inspect
      attrs = self.class.attributes.map do |attr|
        [attr, send(attr)].join("=")
      end.join(" ")
      %Q{#<#{self.class.name} #{attrs}>}
    end

    protected
    attr_reader :data, :client
  end
end
