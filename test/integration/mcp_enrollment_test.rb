# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/tmux_fixture'
require_relative '../support/process_cursor_support'
require 'libtmux/async'
require 'socket'
require 'async/queue'
require 'digest'
require 'libtmux/mcp/enrollment' if File.file?(File.expand_path('../../gems/libtmux-mcp/lib/libtmux/mcp/enrollment.rb', __dir__))

class MCPEnrollmentTest < Minitest::Test
  include LibTmuxTest::ProcessCursorSupport
  def test_enrolled_borrowed_shell_prepares_without_executing_and_observes_one_use_grant
    assert LibTmux::MCP.const_defined?(:EnrollmentRegistry, false), 'explicit shell enrollment is not implemented'
    with_shell do |registry, pane, channel, scope, source|
      digest = Digest::SHA256.hexdigest('exit 7')
      prepared = registry.prepare(pane.ref, script_digest: digest, timeout: 0.5)
      refute prepared.authorized?
      assert_equal pane.id, prepared.reference.id
      grant = prepared.authorize(timeout: 0.5)
      assert_equal 'authorized', grant.fetch('state')
      assert_equal digest, grant.fetch('script_digest')
      assert_equal pane.ref.binding_key, grant.fetch('server_generation')
      assert_equal prepared.process_generation, grant.fetch('process_generation')
      assert_equal prepared.run_id, grant.fetch('run_id')
      assert prepared.authorized?
      nonce = prepared.instance_variable_get(:@authorization)
      assert_raises(LibTmux::DeadlineExceeded) { scope.server.run(['wait-for', nonce], timeout: 0.03) }
      scope.server.run(['wait-for', '-S', nonce])
      assert_raises(LibTmux::ClosedError) { prepared.authorize(timeout: 0.5) }
      prepared.close
      registry.close
      assert source.run(['has-session', '-t', 'enrolled']).success?
      assert_empty scope.server.list_clients
    end
  end

  def test_partial_editor_refuses_without_changing_input_and_pregrant_cancel_has_no_authorization
    with_shell do |registry, pane, _channel, _scope, _source|
      pane.send_text('unfinished-input')
      failure = assert_raises(LibTmux::UnsupportedFeatureError) do
        registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      end
      assert_equal :not_sent, failure.delivery
      assert_includes pane.capture.text, 'unfinished-input'
      pane.send_keys('C-u')
      prepared = registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      token = LibTmux::Internal::Cancellation.new
      token.cancel
      failure = assert_raises(LibTmux::Cancelled) { prepared.authorize(timeout: 0.5, cancel: token) }
      assert_equal :not_sent, failure.delivery
      refute prepared.authorized?
      prepared.close
    ensure
      token&.close
    end
  end

  def test_respawn_before_grant_refuses_and_respawn_after_grant_keeps_the_original_recipient
    with_shell do |registry, pane, _channel, scope, _source|
      prepared = registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      pane.respawn(command: ['cat'], kill: true)
      failure = assert_raises(LibTmux::TargetNotFoundError) { prepared.authorize(timeout: 0.5) }
      assert_equal :not_sent, failure.delivery
      refute prepared.authorized?
      prepared.close
      assert scope.server.snapshot.panes.find { |record| record.id == pane.id }
    end
    with_shell do |registry, pane, _channel, scope, _source|
      prepared = registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      old_pid = scope.server.snapshot.panes.find { |record| record.id == pane.id }.pid
      original = registry.method(:guard)
      registry.define_singleton_method(:guard) do |reference, identity, budget, nonce = nil|
        result = original.call(reference, identity, budget, nonce)
        pane.respawn(command: ['cat'], kill: true) if nonce
        result
      end
      receipt = prepared.authorize(timeout: 0.5)
      replacement = scope.server.snapshot.panes.find { |record| record.id == pane.id }
      refute_equal old_pid, replacement.pid
      assert_equal prepared.process_generation, receipt.fetch('process_generation')
      assert_equal 'authorized', receipt.fetch('state')
      refute_includes pane.capture.text, prepared.run_id
      prepared.close
    end
  end

  def test_cancellation_after_the_committed_grant_keeps_its_exact_effect_receipt
    with_shell do |registry, pane, _channel, _scope, _source|
      prepared = registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      token = LibTmux::Internal::Cancellation.new
      original = registry.method(:guard)
      registry.define_singleton_method(:guard) do |reference, identity, budget, nonce = nil|
        result = original.call(reference, identity, budget, nonce)
        token.cancel if nonce
        result
      end
      failure = assert_raises(LibTmux::Cancelled) { prepared.authorize(timeout: 0.5, cancel: token) }
      assert_equal :possibly_sent, failure.delivery
      assert_equal 'authorized', prepared.receipt.fetch('state')
      assert_equal prepared.process_generation, prepared.receipt.fetch('process_generation')
      prepared.close
    ensure
      token&.close
    end
  end

  def test_close_cancels_a_busy_shell_preparation_and_prevents_delayed_authorization
    with_shell do |registry, pane, channel, _scope, source|
      pane.send_text('test_busy')
      pane.send_keys('Enter')
      assert_equal 'busy', read_line(channel)
      started = Async::Queue.new
      original = registry.method(:accept_socket)
      registry.define_singleton_method(:accept_socket) do |listener, budget|
        started.enqueue(true)
        original.call(listener, budget)
      end
      pending = Async::Task.current.async do
        registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), timeout: 0.5)
      rescue Exception => error
        error
      end
      Async::Task.current.with_timeout(0.5) { started.dequeue }
      registry.close
      assert pending.finished?, 'registry close must retire its active preparation'
      assert_instance_of LibTmux::Cancelled, pending.wait(timeout: 0.5)
      pane.send_keys('Enter')
      assert_equal 'busy-ended', read_line(channel)
      assert_equal 'ready', read_line(channel)
      assert source.run(['has-session', '-t', 'enrolled']).success?
    end
  end

  def test_failed_enrollment_transfer_keeps_the_accepted_channel_and_identity_owned
    acceptor = lambda do |registry, invitation|
      accepted = nil
      identity = invitation.capture.process
      original_accept = registry.method(:accept_socket)
      registry.define_singleton_method(:accept_socket) do |listener, budget|
        accepted = original_accept.call(listener, budget)
      end
      original_close = invitation.listener.method(:close)
      first = true
      invitation.listener.define_singleton_method(:close) do
        if first
          first = false
          raise IOError, 'injected listener close failure'
        end
        original_close.call
      end
      assert_raises(IOError) { registry.accept(invitation, timeout: 0.5) }
      registry.close
      assert accepted.closed?, 'accepted protocol channel must remain owned when invitation retirement fails'
      assert identity.io.closed?, 'the transferred native identity lease must remain owned'
      nil
    ensure
      accepted&.close unless accepted&.closed?
      identity&.close unless identity&.io&.closed?
    end
    with_shell(acceptor: acceptor) { }
  end

  def test_pending_enrollment_rejects_duplicate_reference_before_capture
    acceptor = lambda do |registry, invitation|
      assert_raises(LibTmux::CapacityError) { registry.invite(invitation.reference, timeout: 0.5) }
      registry.accept(invitation, timeout: 0.5)
    end
    with_shell(acceptor: acceptor) { }
  end

  def test_authored_script_preserves_context_separates_binary_output_and_reports_native_status
    with_shell(space_paths: true) do |registry, pane, _channel, _scope, _source, directory|
      assert_respond_to registry, :run, 'authored execution has not been implemented'
      script = %(printf '%s\n' "$PWD" "$LIBTMUX_RUN_TEST_VALUE" "$TMUX_PANE"; printf 'AUTHORIZED fake marker\n'; printf '\\000\\377\\n' >&2; exit 7)
      result = registry.run(pane.ref, script: script, timeout: 0.5, stdout_limit: 8192, stderr_limit: 8192)
      assert_equal "#{directory}\nliteral-value\n#{pane.id}\nAUTHORIZED fake marker\n".b, result.stdout
      assert_equal "\x00\xff\n".b, result.stderr
      assert_equal 7, result.exit_status
      assert_nil result.signal
      assert_equal 'authorized', result.receipt.fetch('state')
      assert_equal Digest::SHA256.hexdigest(script), result.receipt.fetch('script_digest')
    end
  end

  def test_authored_output_overflow_and_cancel_do_not_invent_completion_or_allow_parallel_runs
    with_shell do |registry, pane, _channel, _scope, _source, directory|
      failure = assert_raises(LibTmux::CapacityError) do
        registry.run(pane.ref, script: "printf 123456789", timeout: 0.5, stdout_limit: 8)
      end
      assert_equal :possibly_sent, failure.delivery
      assert_equal 'authorized', failure.run_receipt.fetch('state')

      path = File.join(directory, 'script-ready')
      UNIXServer.open(path) do |listener|
        code = "s=UNIXSocket.new(ARGV.fetch(0));s.puts(Process.pid);s.read"
        script = "exec #{[Gem.ruby, '--disable=rubyopt,gems', '-rsocket', '-e', code, path].map { |value| "'#{value.gsub("'", %q('\''))}'" }.join(' ')}"
        token = LibTmux::Internal::Cancellation.new
        pending = Async::Task.current.async do
          registry.run(pane.ref, script: script, timeout: 0.5, cancel: token)
        rescue Exception => error
          error
        end
        child = listener.accept
        pid = Integer(read_line(child))
        failure = assert_raises(LibTmux::CapacityError) do
          registry.run(pane.ref, script: 'exit 0', timeout: 0.5)
        end
        assert_equal :not_sent, failure.delivery
        token.cancel
        failure = pending.wait(timeout: 0.5)
        assert_instance_of LibTmux::Cancelled, failure
        assert_equal :possibly_sent, failure.delivery
        assert_equal 'authorized', failure.run_receipt.fetch('state')
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        assert_nil child.read(1)
      ensure
        child&.close
        token&.close
      end
    end
  end

  def test_registry_close_keeps_a_runs_final_helper_retirement_owned
    with_shell do |registry, pane, _channel, _scope, _source|
      entered, release, waiting = Async::Queue.new, Async::Queue.new, Async::Queue.new
      closes = 0
      original_prepare = registry.method(:prepare)
      registry.define_singleton_method(:prepare) do |*arguments, **options|
        prepared = original_prepare.call(*arguments, **options)
        original_close = prepared.method(:close)
        prepared.define_singleton_method(:close) do |**close_options|
          closes += 1
          if closes == 1
            entered.enqueue(true)
            begin
              release.dequeue
            rescue Async::Cancel => interrupted
              release.dequeue
            end
          end
          original_close.call(**close_options)
          raise interrupted if interrupted
        end
        prepared
      end
      pending = Async::Task.current.async do
        registry.run(pane.ref, script: 'exit 0', timeout: 0.5)
      rescue Exception => error
        error
      end
      Async::Task.current.with_timeout(0.5) { entered.dequeue }
      changed = registry.instance_variable_get(:@changed)
      original_wait = changed.method(:wait)
      changed.define_singleton_method(:wait) do
        waiting.enqueue(true)
        original_wait.call
      end
      closing = Async::Task.current.async do
        registry.close
      rescue Exception => error
        error
      end
      Async::Task.current.with_timeout(0.5) { waiting.dequeue }
      assert_equal 1, closes, 'registry close must not race the active run cleanup'
      refute closing.finished?, 'registry close must await the run cleanup owner'
      2.times do
        closing.cancel
        Async::Task.current.with_timeout(0.5) { waiting.dequeue }
      end
      refute closing.finished?, 'repeated cancellation must not abandon admitted cleanup'
      release.enqueue(true)
      assert_instance_of Async::Cancel, pending.wait(timeout: 0.5)
      assert_instance_of Async::Cancel, closing.wait(timeout: 0.5)
      assert_empty registry.instance_variable_get(:@runs)
      assert_empty registry.instance_variable_get(:@prepared)
      registry.close
    ensure
      release&.enqueue(true)
      pending&.wait(timeout: 0.5)
      closing&.wait(timeout: 0.5)
    end
  end

  def test_cancellation_watcher_construction_failure_releases_request_admission
    with_shell do |registry, pane, _channel, _scope, _source|
      token = LibTmux::Internal::Cancellation.new
      original_new = Async::Task.method(:new)
      Async::Task.define_singleton_method(:new) { |*| raise IOError, 'injected watcher construction failure' }
      assert_raises(IOError) do
        registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0'), cancel: token)
      end
      assert_empty registry.instance_variable_get(:@calls), 'failed watcher construction must release admission'
    ensure
      Async::Task.define_singleton_method(:new, original_new) if original_new
      registry.instance_variable_get(:@calls).delete(Async::Task.current)
      token&.close
    end
  end

  def test_public_enrollment_and_sdk_run_require_opt_in_and_preserve_completion_evidence
    require 'libtmux/mcp'
    with_shell(app_tools: ['tmux_run']) do |application, pane, _channel, scope, _source|
      readonly = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: 'readonly')
      assert_raises(LibTmux::UnsupportedFeatureError) { readonly.invite_shell(pane.ref, timeout: 0.5) }
      denied = readonly.call('tmux_run', {}).structured_content
      assert_equal 'policy_denied', denied.fetch('error').fetch('code')
      sdk = application.sdk_server
      sdk.handle({jsonrpc: '2.0', id: 1, method: 'initialize', params: {protocolVersion: '2026-07-28', capabilities: {}, clientInfo: {name: 'run-test', version: '1'}}})
      script = "printf 'RESULT hostile output'; printf '\\377' >&2; exit 7"
      reply = sdk.handle({jsonrpc: '2.0', id: 2, method: 'tools/call', params: {name: 'tmux_run', arguments: {
        target: {generation: pane.ref.binding_key, kind: 'pane', id: pane.id}, script: script, stdout_limit: 64, stderr_limit: 64}}})
      structured = JSON.parse(JSON.generate(reply)).fetch('result').fetch('structuredContent')
      assert_equal true, structured.fetch('ok')
      data = structured.fetch('data')
      assert_equal({'state' => 'exited', 'exit_status' => 7, 'signal' => nil}, data.fetch('completion'))
      assert_equal({'encoding' => 'utf-8', 'data' => 'RESULT hostile output', 'bytes' => 21, 'truncated' => false}, data.fetch('stdout'))
      assert_equal({'encoding' => 'base64', 'data' => '/w==', 'bytes' => 1, 'truncated' => false}, data.fetch('stderr'))
      assert_equal 'authorized', data.fetch('authorization').fetch('state')
      assert_equal Digest::SHA256.hexdigest(script), data.fetch('authorization').fetch('script_digest')
      target = {generation: pane.ref.binding_key, kind: 'pane', id: pane.id}
      overflow = sdk.handle({jsonrpc: '2.0', id: 3, method: 'tools/call', params: {name: 'tmux_run', arguments: {
        target: target, script: "printf 'sensitive-overflow-marker'", stdout_limit: 1, stderr_limit: 0}}})
      error = JSON.parse(JSON.generate(overflow)).fetch('result').fetch('structuredContent').fetch('error')
      assert_equal 'capacity', error.fetch('code')
      assert_equal 'known', error.fetch('effects').fetch('state')
      assert_equal({'state' => 'unobserved'}, error.fetch('effects').fetch('completion'))
      refute_includes JSON.generate(error), 'sensitive-overflow-marker'
      limited = LibTmux::MCP::Application.new(server: scope.server, endpoint_name: 'limited', enabled_tools: ['tmux_run'], max_response_bytes: 4096)
      refused = limited.call('tmux_run', {'target' => target.transform_keys(&:to_s), 'script' => 'exit 0', 'stdout_limit' => 1, 'stderr_limit' => 0}).structured_content
      assert_equal 'capacity', refused.fetch('error').fetch('code')
      assert_equal({'state' => 'none', 'authorization' => nil, 'completion' => {'state' => 'unobserved'}}, refused.fetch('error').fetch('effects'))
      registry = application.instance_variable_get(:@shells)
      original_prepare = registry.method(:prepare)
      registry.define_singleton_method(:prepare) do |*arguments, **options|
        prepared = original_prepare.call(*arguments, **options)
        original_close, first = prepared.method(:close), true
        prepared.define_singleton_method(:close) do |**close_options|
          if first
            first = false
            raise IOError, 'injected retirement failure after native completion'
          end
          original_close.call(**close_options)
        end
        prepared
      end
      cleanup = sdk.handle({jsonrpc: '2.0', id: 4, method: 'tools/call', params: {name: 'tmux_run', arguments: {
        target: target, script: 'exit 9', stdout_limit: 0, stderr_limit: 0}}})
      error = JSON.parse(JSON.generate(cleanup)).fetch('result').fetch('structuredContent').fetch('error')
      assert_equal 'observed', error.fetch('delivery')
      assert_equal 'authorized', error.fetch('effects').fetch('authorization').fetch('state')
      assert_equal({'state' => 'exited', 'exit_status' => 9, 'signal' => nil}, error.fetch('effects').fetch('completion'))
      unregisters = 0
      cancellation = Object.new
      cancellation.define_singleton_method(:on_cancel) { |&_| :registration }
      cancellation.define_singleton_method(:off_cancel) do |_registration|
        unregisters += 1
        raise IOError, 'injected callback unregister failure' if unregisters == 1
      end
      failure = assert_raises(LibTmux::CapacityError) do
        application.invite_shell(pane.ref, cancellation: cancellation)
      end
      assert failure.cleanup_errors.any? { |message| message.include?('request retirement') }
      application.close
      assert_equal 2, unregisters, 'application close must retry owned callback retirement'
    ensure
      limited&.close
      readonly&.close
    end
  end

  def test_sdk_callback_retirement_after_result_preserves_native_completion
    require 'libtmux/mcp'
    with_shell(app_tools: ['tmux_run']) do |application, pane, _channel, _scope, _source|
      sdk = application.sdk_server
      session = ::MCP::ServerSession.new(server: sdk, transport: Object.new)
      session.handle({jsonrpc: '2.0', id: 1, method: 'initialize', params: {
        protocolVersion: '2025-11-25', capabilities: {}, clientInfo: {name: 'retirement-test', version: '1'}}})
      register = session.method(:register_in_flight)
      unregisters = 0
      session.define_singleton_method(:register_in_flight) do |id|
        register.call(id).tap do |cancellation|
          original = cancellation.method(:off_cancel)
          cancellation.define_singleton_method(:off_cancel) do |callback|
            unregisters += 1
            raise IOError, 'injected unregister after native RESULT' if unregisters == 1

            original.call(callback)
          end
        end
      end
      reply = session.handle({jsonrpc: '2.0', id: 2, method: 'tools/call', params: {
        name: 'tmux_run', arguments: {target: {generation: pane.ref.binding_key, kind: 'pane', id: pane.id},
          script: 'exit 11', stdout_limit: 0, stderr_limit: 0}}})
      structured = JSON.parse(JSON.generate(reply)).dig('result', 'structuredContent')
      refute_nil structured, 'callback retirement discarded the structured completion receipt'
      error = structured.fetch('error')
      assert_equal 'transport_error', error.fetch('code')
      assert_equal 'observed', error.fetch('delivery')
      assert_equal 'authorized', error.fetch('effects').fetch('authorization').fetch('state')
      assert_equal({'state' => 'exited', 'exit_status' => 11, 'signal' => nil}, error.fetch('effects').fetch('completion'))
      application.close
      assert_equal 2, unregisters
    end
  end

  def test_failed_protocol_constructors_keep_native_references_and_socket_paths_owned
    with_shell do |registry, pane, _channel, _scope, _source|
      directory = registry.instance_variable_get(:@directory)
      identity = registry.instance_variable_get(:@enrollments).fetch(pane.ref).capture.process
      before_references = identity.instance_variable_get(:@references)
      before_paths = Dir.children(directory)
      original_hex, original_socket = SecureRandom.method(:hex), UNIXServer.method(:new)
      created = nil
      SecureRandom.define_singleton_method(:hex) { |count| count == 32 ? raise(IOError, 'injected authorization allocation failure') : original_hex.call(count) }
      UNIXServer.define_singleton_method(:new) { |*args| created = original_socket.call(*args) }
      assert_raises(IOError) { registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0')) }
      assert created.closed?, 'failed helper construction must close its provisional listener'
      assert_equal before_paths, Dir.children(directory)
      assert_equal before_references, identity.instance_variable_get(:@references)
      SecureRandom.define_singleton_method(:hex, original_hex)
      UNIXServer.define_singleton_method(:new, original_socket)
      channel = registry.instance_variable_get(:@enrollments).fetch(pane.ref).channel
      channel.define_singleton_method(:write) do |_line, _budget|
        io.write_nonblock('P ')
        raise LibTmux::DeadlineExceeded.new('injected partial preparation write', delivery: :possibly_sent)
      end
      assert_raises(LibTmux::DeadlineExceeded) { registry.prepare(pane.ref, script_digest: Digest::SHA256.hexdigest('exit 0')) }
      assert channel.io.closed?, 'ambiguous preparation must retire the corrupted enrollment stream'
      refute registry.instance_variable_get(:@enrollments).key?(pane.ref)
    ensure
      SecureRandom.define_singleton_method(:hex, original_hex) if original_hex
      UNIXServer.define_singleton_method(:new, original_socket) if original_socket
      created&.close unless created&.closed?
      (Dir.children(directory) - before_paths).each { |name| File.unlink(File.join(directory, name)) } if directory
      identity.close if identity && identity.instance_variable_get(:@references) > before_references
    end
    acceptor = lambda do |registry, invitation|
      klass = LibTmux::MCP.const_get(:EnrollmentRegistry)::Enrollment
      identity = invitation.capture.process
      original_new = klass.method(:new)
      klass.define_singleton_method(:new) { |*| raise IOError, 'injected enrollment construction failure' }
      assert_raises(IOError) { registry.accept(invitation) }
      assert identity.io.closed?, 'failed enrollment construction must release every native reference'
      nil
    ensure
      klass.define_singleton_method(:new, original_new)
      identity.close unless identity.io.closed?
    end
    with_shell(acceptor: acceptor) { }
  end

  private

  def read_line(io)
    result = +''
    Async::Task.current.with_timeout(0.5) do
      until result.end_with?("\n")
        value = io.read_nonblock(1, exception: false)
        if value == :wait_readable
          Fiber.scheduler.io_wait(io, IO::READABLE)
        elsif value
          result << value
        else
          raise 'unexpected enrollment test EOF'
        end
      end
    end
    result.chomp
  end

  def with_shell(acceptor: nil, space_paths: false, app_tools: nil)
    Dir.mktmpdir(space_paths ? '' : 'libtmux-ruby-enrollment-test-') do |directory|
      if space_paths
        directory = File.join(directory, 'x y')
        Dir.mkdir(directory)
      end
      path = File.join(directory, 'test-control')
      UNIXServer.open(path) do |listener|
        File.write(File.join(directory, '.zshrc'), <<~ZSH)
          zmodload zsh/net/socket
          zsocket '#{path}' || exit 80
          typeset -g test_control=$REPLY
          print -r -- initializing >&$test_control
          IFS= read -r integration <&$test_control
          IFS= read -r socket <&$test_control
          IFS= read -r token <&$test_control
          IFS= read -r ruby <&$test_control
          IFS= read -r helper <&$test_control
          IFS= read -r loadpath <&$test_control
          source "$integration" "$socket" "$token" "$ruby" "$helper" "$loadpath" || { print -r -- refused >&$test_control; exit 81; }
          export LIBTMUX_RUN_TEST_VALUE=literal-value
          cd '#{directory}'
          trap '' HUP
          PS1=''
          test_busy() { print -r -- busy >&$test_control; IFS= read -r ignored; print -r -- busy-ended >&$test_control; }
          test_ready() { print -r -- ready >&$test_control }
          zle -N zle-line-init test_ready
        ZSH
        LibTmuxTest::TmuxFixture.open do |fixture|
          LibTmux::Server.open(socket_path: fixture.socket_path, executable: fixture.executable) do |source|
            Async do |task|
              LibTmux::Async.open(server: source, parent: task) do |scope|
                begin
                previous_tmpdir = ENV['TMPDIR']
                begin
                  ENV['TMPDIR'] = directory if space_paths
                  registry = if app_tools
                    LibTmux::MCP::Application.new(server: scope.server, endpoint_name: 'enrolled', enabled_tools: app_tools, request_timeout: 0.5)
                  else
                    LibTmux::MCP.const_get(:EnrollmentRegistry).new(server: scope.server, parent: task)
                  end
                ensure
                  previous_tmpdir ? ENV['TMPDIR'] = previous_tmpdir : ENV.delete('TMPDIR')
                end
                unless process_cursor_tmux_supported?(scope)
                  pane = scope.server.list_panes.first
                  before = Dir.children(directory)
                  failure = assert_raises(LibTmux::UnsupportedFeatureError) do
                    app_tools ? registry.invite_shell(pane.ref, timeout: 0.5) : registry.invite(pane.ref, timeout: 0.5)
                  end
                  assert_equal :not_sent, failure.delivery
                  assert_equal before, Dir.children(directory), 'refused enrollment created setup files'
                  assert_equal [pane.id], scope.server.list_panes.map(&:id), 'refused enrollment changed pane topology'
                  next
                end
                pane = scope.server.new_session(name: 'enrolled', command: ['/usr/bin/env', "ZDOTDIR=#{directory}", '/bin/zsh', '-d', '-i']).list_panes.first
                channel = listener.accept
                assert_equal 'initializing', read_line(channel)
                invitation = app_tools ? registry.invite_shell(pane.ref, timeout: 0.5) : registry.invite(pane.ref, timeout: 0.5)
                channel.puts invitation.shell_arguments
                enrollment = if app_tools
                  registry.accept_shell(invitation, timeout: 0.5)
                else
                  acceptor ? acceptor.call(registry, invitation) : registry.accept(invitation, timeout: 0.5)
                end
                assert_equal pane.id, (app_tools ? enrollment : enrollment.reference).id if enrollment
                assert_equal(enrollment ? 'ready' : 'refused', read_line(channel))
                  yield registry, pane, channel, scope, source, directory
                ensure
                  registry&.close
                  channel&.close
                end
              end
            end.wait
          end
        end
      end
    end
  end
end
