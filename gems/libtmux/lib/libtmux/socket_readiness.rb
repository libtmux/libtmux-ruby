# frozen_string_literal: true

require "fcntl"
require "fiddle"
require "libtmux/errors"

module LibTmux
  module Internal
    class InotifyReadinessEvents
      attr_reader :reader

      def initialize(directory, mask: 0x00000004)
        libc = Fiddle::Handle::DEFAULT
        init = Fiddle::Function.new(libc["inotify_init1"], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        add = Fiddle::Function.new(libc["inotify_add_watch"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
        fd = init.call(Fcntl::O_NONBLOCK)
        raise SystemCallError.new("inotify_init1", Fiddle.last_error) if fd.negative?

        @reader = IO.for_fd(fd, autoclose: true)
        @reader.close_on_exec = true
        @watch = add.call(fd, directory, mask)
        raise SystemCallError.new("inotify_add_watch", Fiddle.last_error) if @watch.negative?
      rescue Exception
        close
        raise
      end

      def drain(pid)
        bytes = @reader.read_nonblock(16_384, exception: false)
        return [] unless bytes.is_a?(String)

        offset = 0
        events = []
        while offset < bytes.bytesize
          header = bytes.byteslice(offset, 16)
          raise ProtocolError.new("truncated socket readiness event", phase: :startup, pid: pid, delivery: :possibly_sent) unless header.bytesize == 16

          descriptor, mask, _, size = header.unpack("iIII")
          if mask & 0x00004000 != 0 # IN_Q_OVERFLOW
            raise CapacityError.new("socket readiness events overflowed", phase: :startup, pid: pid, delivery: :possibly_sent)
          end
          name = bytes.byteslice(offset + 16, size)
          raise ProtocolError.new("truncated socket readiness name", phase: :startup, pid: pid, delivery: :possibly_sent) unless name && name.bytesize == size

          events << [mask, name.delete("\0")] if descriptor == @watch
          offset += 16 + size
        end
        events
      end

      def watch_file(_io); end

      def close
        @reader.close if @reader && !@reader.closed?
      end
    end

    class KqueueReadinessEvents
      attr_reader :reader

      def initialize(directory)
        unless Fiddle::SIZEOF_VOIDP == 8
          raise UnsupportedFeatureError.new("owned daemon readiness requires 64-bit Darwin", phase: :startup)
        end
        libc = Fiddle::Handle::DEFAULT
        create = Fiddle::Function.new(libc["kqueue"], [], Fiddle::TYPE_INT)
        @kevent = Fiddle::Function.new(libc["kevent"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP,
          Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
        fd = create.call
        raise SystemCallError.new("kqueue", Fiddle.last_error) if fd.negative?

        @reader = IO.for_fd(fd, autoclose: true)
        @reader.close_on_exec = true
        @directory = File.open(directory, File::RDONLY)
        @directory.close_on_exec = true
        watch_file(@directory)
      rescue Exception
        close
        raise
      end

      def watch_file(io)
        # Darwin's 64-bit struct kevent: ident, filter, flags, fflags, data, udata.
        # EVFILT_VNODE, EV_ADD|EV_CLEAR, NOTE_WRITE|DELETE|RENAME|REVOKE.
        change = [io.fileno, -4, 0x21, 0x63, 0, 0].pack("QsS I qQ")
        result = @kevent.call(@reader.fileno, change, 1, nil, 0, nil)
        raise SystemCallError.new("kevent registration", Fiddle.last_error) if result.negative?
      end

      def drain(pid)
        buffer = "\0".b * 256
        zero_timeout = [0, 0].pack("q2")
        count = @kevent.call(@reader.fileno, nil, 0, buffer, 8, zero_timeout)
        if count.negative?
          return if Fiddle.last_error == Errno::EINTR::Errno

          raise SystemCallError.new("kevent readiness", Fiddle.last_error)
        end
        count.times do |index|
          _, _, flags, notes, error, = buffer.byteslice(index * 32, 32).unpack("QsS I qQ")
          raise SystemCallError.new("kevent event", error) if flags & 0x4000 != 0
          if notes & 0x61 != 0
            raise TransportError.new("owned startup log changed identity", phase: :startup, pid: pid, delivery: :possibly_sent)
          end
        end
      end

      def close
        failure = nil
        [@reader, @directory].compact.each do |io|
          begin
            io.close unless io.closed?
          rescue Exception => error
            failure ||= error
          end
        end
        raise failure if failure
      end
    end

    class SocketReadiness
      def self.new(directory)
        return LogSocketReadiness.new(directory) if RUBY_PLATFORM.include?("darwin")
        unless RUBY_PLATFORM.include?("linux")
          raise UnsupportedFeatureError.new("owned daemon readiness requires Linux or Darwin", phase: :startup)
        end

        super
      end

      def initialize(directory)
        @events = InotifyReadinessEvents.new(directory)
      end

      def reader = @events.reader
      def arguments = []
      def spawn_options = {}
      def remove_files(_pid); end

      def ready?(child)
        # tmux's initial chmod follows bind/listen; no client can cause it yet.
        @events.drain(child.pid).any? { |mask, name| mask & 0x00000004 != 0 && name == "socket" }
      end

      def close = @events.close
    end

    class LogSocketReadiness
      attr_reader :bytes_read

      def initialize(directory)
        @directory, @bytes_read, @tail = directory, 0, +"".b
        @events = if RUBY_PLATFORM.include?("darwin")
          KqueueReadinessEvents.new(directory)
        elsif RUBY_PLATFORM.include?("linux")
          InotifyReadinessEvents.new(directory, mask: 0x00000102) # IN_CREATE|IN_MODIFY
        else
          raise UnsupportedFeatureError.new("owned log readiness requires Linux or Darwin", phase: :startup)
        end
      end

      def reader = @events.reader
      def arguments = ["-v"]
      def spawn_options = {chdir: @directory}
      def stopped? = !!@stopped

      def ready?(child)
        return true if @stopped

        @events.drain(child.pid)
        unless @log
          begin
            @log = File.open(File.join(@directory, "tmux-server-#{child.pid}.log"), File::RDONLY | File::NOFOLLOW)
          rescue Errno::ENOENT
            return false
          end
          @log.close_on_exec = true
          unless @log.stat.file?
            raise ProtocolError.new("owned startup log is not a regular file", phase: :startup, pid: child.pid, delivery: :possibly_sent)
          end
          # Register before reading: an append between registration and EOF stays queued.
          @events.watch_file(@log)
        end
        while (bytes = @log.read(16_384))
          @bytes_read += bytes.bytesize
          if @bytes_read > 1 << 20
            raise CapacityError.new("owned startup log exceeded byte limit", phase: :startup, pid: child.pid, delivery: :possibly_sent)
          end
          text = @tail + bytes
          if !@stopping && text.match?(/(?:\A|\n)\d+\.\d+ server loop enter\n/n)
            child.signal("USR2")
            @stopping = true
          end
          if @stopping && text.match?(/(?:\A|\n)\d+\.\d+ log closed\n/n)
            @stopped = true
            return true
          end
          @tail = text.byteslice(-128, 128) || text
        end
        false
      end

      def remove_files(pid)
        return unless pid

        %w[client server].each do |kind|
          path = File.join(@directory, "tmux-#{kind}-#{pid}.log")
          File.unlink(path) if File.exist?(path)
        end
      end

      def close
        failure = nil
        begin
          @log.close if @log && !@log.closed?
        rescue Exception => error
          failure = error
        ensure
          begin
            @events.close
          rescue Exception => error
            failure ||= error
          end
        end
        raise failure if failure
      end
    end

    private_constant :InotifyReadinessEvents, :KqueueReadinessEvents, :SocketReadiness, :LogSocketReadiness
  end
end
