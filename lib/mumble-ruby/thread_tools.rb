module Mumble
  module ThreadTools
    class DuplicateThread < StandardError; end

    protected
    def spawn_thread(sym)
      raise DuplicateThread if threads.has_key? sym
      threads[sym] = Thread.new { loop { send sym } }
    end

    def spawn_threads(*symbols)
      symbols.map { |sym| spawn_thread sym }
    end

    def kill_threads
      threads.values.map(&:kill)
      threads.clear
    end

    def threads
      @threads ||= {}
    end
  end
end
