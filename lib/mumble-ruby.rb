require 'opus-ruby'
require 'active_support/inflector'
require 'mumble-ruby/version'
require 'mumble-ruby/thread_tools'
require 'mumble-ruby/messages'
require 'mumble-ruby/connection'
require 'mumble-ruby/model'
require 'mumble-ruby/user'
require 'mumble-ruby/channel'
require 'mumble-ruby/client'
require 'mumble-ruby/audio_player'
require 'mumble-ruby/packet_data_stream'
require 'mumble-ruby/img_reader'
require 'mumble-ruby/cert_manager'
require 'mumble-ruby/audio_recorder'
require 'hashie'

module Mumble
  DEFAULTS = {
    sample_rate: 48000,
    bitrate: 32000,
    ssl_cert_opts: {
      cert_dir: File.expand_path("./"),
      country_code: "US",
      organization: "github.com",
      organization_unit: "Engineering"
    }
  }

  def self.configuration
    @configuration ||= Hashie::Mash.new(DEFAULTS)
  end

  def self.configure
    yield(configuration) if block_given?
  end

  Thread.abort_on_exception = true
end
