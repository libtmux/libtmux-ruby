# frozen_string_literal: true

# Diagnostic preload only; the installed gems never require this file.
require "libtmux/child"
require "json"
require "minitest/autorun"

module NativeChildTrace
  STARTED = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  LOCK = Mutex.new
  EVENTS = []

  def self.record(phase, owner, detail = nil)
    event = {seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - STARTED,
      thread: Thread.current.object_id, owner: owner.object_id, phase: phase, detail: detail}
    LOCK.synchronize { EVENTS << event }
  end
end

LibTmux::Internal::OwnedChild.prepend(Module.new do
  [:spawned, :signal, :wait_observed, :finish_signalling, :join].each do |name|
    define_method(name) do |*arguments, &block|
      NativeChildTrace.record("#{name}:enter", self, arguments)
      result = super(*arguments, &block)
      NativeChildTrace.record("#{name}:leave", self, !!result)
      result
    rescue Exception => error
      NativeChildTrace.record("#{name}:error", self, error.class.name)
      raise
    end
  end
end)

LibTmux::Internal::ProcessWait.prepend(Module.new do
  def observe(pid)
    NativeChildTrace.record("waitid:enter", self, pid)
    super
  ensure
    NativeChildTrace.record("waitid:leave", self, pid)
  end
end)

Process.singleton_class.prepend(Module.new do
  def wait2(*arguments)
    NativeChildTrace.record("wait2:enter", self, arguments)
    super
  ensure
    NativeChildTrace.record("wait2:leave", self, arguments)
  end
end)

Minitest.after_run do
  report = {ruby: RUBY_DESCRIPTION, platform: RUBY_PLATFORM, clock: "CLOCK_MONOTONIC",
    elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - NativeChildTrace::STARTED,
    events: NativeChildTrace::LOCK.synchronize { NativeChildTrace::EVENTS.dup }}
  File.write(ENV.fetch("CHILD_TRACE"), JSON.pretty_generate(report))
end
