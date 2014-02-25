require 'opus-ruby'
require 'active_support/inflector.rb'
require 'mumble-ruby/version'
require 'mumble-ruby/messages.rb'
require 'mumble-ruby/connection.rb'
require 'mumble-ruby/client.rb'
require 'mumble-ruby/audio_stream.rb'
require 'mumble-ruby/packet_data_stream.rb'
require 'mumble-ruby/img_reader.rb'
require 'mumble-ruby/cert_manager.rb'

module Mumble
  Thread.abort_on_exception = true
end
