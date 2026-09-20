# frozen_string_literal: true

require 'socket'
require 'digest/sha2'
require 'libtmux/process'

# This process is launched with explicit installed load paths and disabled gems.
class AuthoredShellHelper
  def initialize(socket, deadline)
    @socket, @deadline, @buffer = socket, deadline, +''.b
  end

  def remaining
    value = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise LibTmux::DeadlineExceeded.new('helper deadline expired') unless value.positive?

    value
  end

  def read_line
    until (ending = @buffer.index("\n"))
      raise LibTmux::ProtocolError.new('helper frame is too large') if @buffer.bytesize >= 1024

      read_more(1024 - @buffer.bytesize)
    end
    @buffer.slice!(0, ending + 1).chomp
  end

  def read_bytes(length)
    read_more([length - @buffer.bytesize, 16_384].min) while @buffer.bytesize < length
    @buffer.slice!(0, length)
  end

  def write(bytes)
    offset = 0
    while offset < bytes.bytesize
      duration = remaining
      count = @socket.write_nonblock(bytes.byteslice(offset, 16_384), exception: false)
      if count == :wait_writable
        IO.select(nil, [@socket], nil, duration)
      else
        offset += count
      end
    end
  end

  private

  def read_more(limit)
    duration = remaining
    bytes = @socket.read_nonblock(limit, exception: false)
    if bytes == :wait_readable
      IO.select([@socket], nil, nil, duration)
    elsif bytes
      @buffer << bytes
    else
      raise EOFError
    end
  end
end

begin
  path, token, deadline_text, run_id, digest, readiness = ARGV
  path = path.unpack1('m0')
  raise ArgumentError unless ARGV.length == 6 && /\A[0-9a-f]{32}\z/.match?(token) &&
    /\A[0-9a-f]{32}\z/.match?(run_id) && /\A[0-9a-f]{64}\z/.match?(digest)
  deadline = Float(deadline_text)
  raise ArgumentError unless deadline.finite?
  socket = UNIXSocket.new(path)
  wire = AuthoredShellHelper.new(socket, deadline)
  prefix = readiness == 'ready' ? 'READY' : 'REFUSED'
  wire.write("#{prefix} #{run_id} #{token} #{digest} #{Process.ppid}\n")
  exit 72 unless readiness == 'ready'
  raise LibTmux::ProtocolError.new('invalid helper grant') unless wire.read_line == "GRANT #{run_id} #{token} #{digest}"

  wire.write("AUTHORIZED #{run_id} #{token} #{digest}\n")
  fields = wire.read_line.split(' ')
  unless fields.length == 7 && fields[0, 4] == ['SCRIPT', run_id, token, digest] && fields[4, 3].all? { |value| /\A\d{1,6}\z/.match?(value) }
    raise LibTmux::ProtocolError.new('invalid helper script envelope')
  end
  length, stdout_limit, stderr_limit = fields[4, 3].map(&:to_i)
  unless length <= 65_536 && stdout_limit <= 262_144 && stderr_limit <= 262_144
    raise LibTmux::ProtocolError.new('invalid helper script limits')
  end
  script = wire.read_bytes(length)
  unless !script.include?("\0") && Digest::SHA256.hexdigest(script) == digest
    raise LibTmux::ProtocolError.new('helper script digest mismatch')
  end

  cancellation = LibTmux::Internal::Cancellation.new
  wake_reader, wake_writer = IO.pipe
  watcher = Thread.new do
    ready = IO.select([socket, wake_reader])
    if ready.first.include?(socket)
      # EOF or unsolicited client bytes revoke this helper's outstanding work.
      socket.read_nonblock(1, exception: false)
      cancellation.cancel
    end
  end
  environment = %w[TMUX TMUX_PANE].filter_map { |name| "#{name}=#{ENV.fetch(name)}" if ENV.key?(name) }
  result = LibTmux::Internal::ProcessExecutor.new(stdout_limit: stdout_limit, stderr_limit: stderr_limit,
    cleanup_timeout: 0.25, drain_timeout: 0.25).run(['/usr/bin/env', *environment, '/bin/sh', '-c', script],
      timeout: wire.remaining, cancel: cancellation)
  wake_writer.write_nonblock('x', exception: false)
  unless watcher.join(0.25)
    raise LibTmux::TransportError.new('helper cancellation watcher remains active', cleanup_errors: ['watcher retirement remains pending'])
  end
  watcher = nil
  kind, status = result.status.exited? ? ['EXIT', result.status.exitstatus] : ['SIGNAL', result.status.termsig]
  wire.write("RESULT #{run_id} #{token} #{digest} #{kind} #{status} #{result.stdout.bytesize} #{result.stderr.bytesize}\n")
  wire.write(result.stdout)
  wire.write(result.stderr)
rescue LibTmux::Error => error
  code = case error
  when LibTmux::CapacityError then 'capacity'
  when LibTmux::DeadlineExceeded then 'deadline'
  when LibTmux::Cancelled then 'cancelled'
  when LibTmux::ProtocolError then 'protocol'
  else 'unknown'
  end
  begin
    wire&.write("ERROR #{run_id} #{token} #{digest} #{code} #{error.cleanup_errors.empty? ? 'clean' : 'pending'}\n")
  rescue StandardError
    # The client observes unknown completion when the bounded channel is gone.
  end
  exit 78
rescue ArgumentError, SystemCallError, IOError, EOFError
  exit 77
ensure
  if watcher
    wake_writer.write_nonblock('x', exception: false)
    retired = watcher.join(0.25)
  end
  [wake_reader, wake_writer, socket].compact.each { |io| io.close unless io.closed? }
  cancellation&.close
  exit 79 if watcher && !retired
end
