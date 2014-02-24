require 'base64'

module Mumble
  class UnsupportedImgFormat < StandardError
    def initialize
      super "Image format must be one of the following: #{ImgReader::FORMATS}"
    end
  end

  class ImgTooLarge < StandardError
    def initialize
      super "Image must be smaller than 128 kB"
    end
  end

  class ImgReader
    attr_reader :file
    FORMATS = %w(png jpg jpeg svg)

    def initialize(file)
      @file = file
      raise LoadError.new("#{file} not found") unless File.exists? file
      raise UnsupportedImgFormat unless FORMATS.include? ext
      raise ImgTooLarge unless File.size(file) <= 128 * 1024
    end

    def ext
      @ext ||= File.extname(@file)[1..-1]
    end

    def data
      @data ||= File.read @file
    end

    def to_msg
      "<img src='data:image/#{ext};base64,#{Base64.encode64(data)}'/>"
    end
  end
end
