module Mumble
  class PacketDataStream
    def initialize(data=nil)
      @data = data || 0.chr * 1024
      @data = @data.split ''
      @pos = 0
      @ok = true
      @capacity = @data.size
    end

    def valid
      @ok
    end

    def size
      @pos
    end

    def left
      @capacity - @pos
    end

    def append(val)
      if @pos < @capacity
        @data[@pos] = val.chr
        skip
      else
        @ok = false
      end
    end

    def append_block(data)
      len = data.size
      if len < left
        @data[@pos, len] = data.split('')
        skip len
      else
        @ok = false
      end
    end

    def get_block(len)
      if len < left
        ret = @data[@pos, len]
        skip len
      else
        @ok = false
        ret = []
      end
      ret
    end

    def get_next
      if @pos < @capacity
        ret = @data[@pos].ord
        skip
      else
        ret = 0
        @ok = false
      end
      ret
    end

    def rewind
      @pos = 0
    end

    def skip(len=1)
      len < left ? @pos += len : @ok = false
    end

    def put_int(int)
      if !(int & 0x8000000000000000).zero? && (~int < 0x100000000)
        int = ~int
        puts int
        if int <= 0x3
          # Shortcase for -1 to -4
          append(0xFC | int)
        else
          append(0xF8)
        end
      end

      if int < 0x80
        # Need top bit clear
        append(int)
      elsif int < 0x4000
        # Need top two bits clear
        append((int >> 8) | 0x80)
        append(int & 0xFF)
      elsif int < 0x200000
        # Need top three bits clear
        append((int >> 16) | 0xC0)
        append((int >> 8) & 0xFF)
        append(int & 0xFF)
      elsif int < 0x10000000
        # Need top four bits clear
        append((int >> 24) | 0xE0)
        append((int >> 16) & 0xFF)
        append((int >> 8) & 0xFF)
        append(int & 0xFF)
      elsif int < 0x100000000
        # It's a full 32-bit integer.
        append(0xF0)
        append((int >> 24) & 0xFF)
        append((int >> 16) & 0xFF)
        append((int >> 8) & 0xFF)
        append(int & 0xFF)
      else
        # It's a 64-bit value.
        append(0xF4)
        append((int >> 56) & 0xFF)
        append((int >> 48) & 0xFF)
        append((int >> 40) & 0xFF)
        append((int >> 32) & 0xFF)
        append((int >> 24) & 0xFF)
        append((int >> 16) & 0xFF)
        append((int >> 8) & 0xFF)
        append(int & 0xFF)
      end
    end

    def get_int
      v = get_next
      int = 0

      if (v & 0x80) == 0x00
        int = v & 0x7F
      elsif (v & 0xC0) == 0x80
        int = (v & 0x3F) << 8 | get_next
      elsif (v & 0xF0) == 0xF0
        x = v & 0xFC
        if x == 0xF0
          int = get_next << 24 | get_next << 16 | get_next << 8 | get_next
        elsif x == 0xF4
          int = get_next << 56 | get_next << 48 | get_next << 40 | get_next << 32 |
                get_next << 24 | get_next << 16 | get_next << 8  | get_next
        elsif x == 0xF8
          int = get_int
          int = ~int
        elsif x == 0xFC
          int = v & 0x03
          int = ~int
        else
          @ok = false
          int = 0
        end
      elsif (v & 0xF0) == 0xE0
        int = (v & 0x0F) << 24 | get_next << 16 | get_next << 8 | get_next
      elsif (v & 0xE0) == 0xC0
        int = (v & 0x1F) << 16 | get_next << 8 | get_next
      end

      return int
    end
  end
end
