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
    class << self
      FORMATS = %w(png jpg jpeg svg)

      def msg_from_file(file)
        @@file = file
        @@ext = File.extname(@@file)[1..-1]
        validate_file

        data = File.read @@file
        "<img src='data:image/#{@@ext};base64,#{Base64.encode64(data)}'/>"
      end

      private
      def validate_file
        raise LoadError.new("#{@@file} not found") unless File.exists? @@file
        raise UnsupportedImgFormat unless FORMATS.include? @@ext
        raise ImgTooLarge unless File.size(@@file) <= 128 * 1024
      end
    end
  end
end
