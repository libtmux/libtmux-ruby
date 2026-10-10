# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"
require "socket"

class LifecycleTest < Minitest::Test
  def test_owned_session_block_returns_body_value_and_removes_only_its_session
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        fixture_ids = server.list_sessions.map(&:id)
        result = server.owned_session(name: "scope", command: ["cat"]) do |session|
          assert_includes server.list_sessions.map(&:id), session.id
          :body_value
        end
        assert_equal :body_value, result
        assert_equal fixture_ids, server.list_sessions.map(&:id)
      end
    end
  end

  def test_owned_resource_is_explicit_and_cleanup_is_repeatable
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.new_session(name: "adopt", command: ["cat"])
        owner = session.adopt
        assert_same session, owner.resource
        assert_match(/\A[0-9a-f]{32}\z/, owner.receipt.generation)
        refute owner.closed?
        owner.close
        assert owner.closed?
        assert_nil owner.close
        refute_includes server.list_sessions.map(&:id), session.id
      end
    end
  end

  def test_all_entity_kinds_follow_ids_after_rename_and_move
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.owned_session(name: "rename", command: ["cat"])
        window = session.resource.owned_window(name: "moving", command: ["cat"])
        pane = window.resource.owned_pane(direction: :horizontal, command: ["cat"])
        fixture.tmux("rename-session", "-t", session.resource.id, "renamed")
        fixture.tmux("move-window", "-s", window.resource.id, "-t", "$0:9")
        fixture.tmux("move-pane", "-s", pane.resource.id, "-t", "%0")
        pane.close
        refute_includes server.list_panes.map(&:id), pane.resource.id
        window.close
        refute_includes server.list_windows.map(&:id), window.resource.id
        session.close
        assert_equal ["$0"], server.list_sessions.map(&:id)
      end
    end
  end

  def test_window_adoption_destroys_all_links_and_panes
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.new_session(name: "linked", command: ["cat"])
        window = session.list_windows.first
        pane = window.list_panes.first
        fixture.tmux("link-window", "-s", window.id, "-t", "$0:9")
        window.adopt { |borrowed| assert_same window, borrowed }
        refute_includes server.list_windows.map(&:id), window.id
        refute_includes server.list_panes.map(&:id), pane.id
        assert_empty server.list_window_links.select { |link| link.id == window.id }
      end
    end
  end

  def test_body_failure_cleanup_failure_and_retry_preserve_original_exceptions
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        owner = server.owned_session(name: "failure", command: ["cat"])
        body = RuntimeError.new("body")
        cleanup = IOError.new("cleanup")
        original = server.method(:destroy_owned)
        server.define_singleton_method(:destroy_owned) { |*, **| raise cleanup }
        error = assert_raises(LibTmux::CleanupError) { owner.use { raise body } }
        assert_same body, error.body_error
        assert_same cleanup, error.cleanup_error
        assert_same owner, error.recovery
        assert_same cleanup, owner.cleanup_error
        refute owner.closed?
        assert_includes server.list_sessions.map(&:id), owner.resource.id
        server.define_singleton_method(:destroy_owned, original)
        owner.close
        assert owner.closed?
        assert_nil owner.cleanup_error
      end
    end
  end

  def test_block_break_and_throw_clean_up
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        assert_equal :break_value, server.owned_session(name: "break", command: ["cat"]) { break :break_value }
        assert_equal :throw_value, catch(:done) { server.owned_session(name: "throw", command: ["cat"]) { throw :done, :throw_value } }
        assert_equal ["$0"], server.list_sessions.map(&:id)
      end
    end
  end

  def test_invalid_generation_fails_without_creating_or_overwriting
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        ["", "bad", "a" * 33].each do |token|
          server.options(scope: :server).set("@libtmux_owner_generation", token)
          assert_raises(LibTmux::ProtocolError) { server.owned_session(name: "invalid", command: ["cat"]) }
          assert_equal ["$0"], server.list_sessions.map(&:id)
          assert_equal token, server.options(scope: :server).get("@libtmux_owner_generation").as(:string)
        end
        token = "abcdef0123456789" * 2
        server.options(scope: :server).set("@libtmux_owner_generation", token)
        owner = server.owned_session(name: "valid", command: ["cat"])
        assert_equal token, owner.receipt.generation
        owner.close
      end
    end
  end

  def test_generation_guard_refuses_same_numeric_identity_with_different_token_for_every_kind
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.owned_session(name: "guard", command: ["cat"])
        window = session.resource.owned_window(name: "guard", command: ["cat"])
        pane = window.resource.owned_pane(direction: :horizontal, command: ["cat"])
        daemon = server.adopt
        token = session.receipt.generation
        server.options(scope: :server).set("@libtmux_owner_generation", "b" * 32 == token ? "c" * 32 : "b" * 32)
        [pane, window, session, daemon].each do |owner|
          assert_raises(LibTmux::TargetNotFoundError) { owner.close }
          refute owner.closed?
        end
        assert_includes server.list_panes.map(&:id), pane.resource.id
        server.options(scope: :server).set("@libtmux_owner_generation", token)
        [pane, window, session].each(&:close)
      end
    end
  end

  def test_complete_receipt_with_duplicate_record_rolls_back
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        original = server.method(:lifecycle_execute)
        server.define_singleton_method(:lifecycle_execute) do |program, names, budget|
          result = original.call(program, names, budget)
          next result unless program.include?("'new-session'")
          LibTmux::CommandResult.new(stdout: result.stdout * 2, stderr: result.stderr, status: result.status,
            elapsed_seconds: result.elapsed_seconds, pid: result.pid, argv: result.argv)
        end
        assert_raises(LibTmux::ProtocolError) { server.owned_session(name: "duplicate", command: ["cat"]) }
        assert_equal ["$0"], server.list_sessions.map(&:id)
      end
    end
  end

  def test_find_or_create_reports_created_reused_and_ambiguity
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        first = server.find_or_create_session(name: "find", command: ["cat"])
        second = server.find_or_create_session(name: "find", command: ["cat"])
        assert first.created?
        refute second.created?
        assert_nil second.owner
        assert_equal first.resource, second.resource
        window = first.resource.find_or_create_window(name: "find", command: ["cat"])
        refute first.resource.find_or_create_window(name: "find", command: ["cat"]).created?
        pane = window.resource.find_or_create_pane(identity: "worker-λ", direction: :horizontal, command: ["cat"])
        refute window.resource.find_or_create_pane(identity: "worker-λ", direction: :horizontal, command: ["cat"]).created?
        window.resource.list_panes.find { |candidate| candidate.id != pane.resource.id }.options.set("@libtmux_pane_identity", "worker-λ")
        assert_raises(LibTmux::MultipleMatchesError) { window.resource.find_or_create_pane(identity: "worker-λ", direction: :horizontal, command: ["cat"]) }
        first.resource.new_window(name: "find", command: ["cat"])
        assert_raises(LibTmux::MultipleMatchesError) { first.resource.find_or_create_window(name: "find", command: ["cat"]) }
        first.owner.close
      end
    end
  end

  def test_threads_share_find_or_create_serialization_across_bindings
    LibTmuxTest::TmuxFixture.open do |fixture|
      workers = 4.times.map do
        Thread.new do
          server = LibTmux::Server.new(socket_path: fixture.socket_path)
          [server, server.find_or_create_session(name: "concurrent", command: ["cat"])]
        end
      end
      workers.each(&:join)
      results = workers.map(&:value)
      assert_equal 1, results.count { |_, result| result.created? }
      assert_equal 1, results.map { |_, result| result.resource.id }.uniq.length
    ensure
      results&.each { |server, result| result.owner&.close; server.close }
    end
  end

  def test_discovery_is_bounded_and_reports_stale_symlink_and_missing_roots
    LibTmuxTest::TmuxFixture.open do |first|
      LibTmuxTest::TmuxFixture.open do |second|
        root = File.dirname(first.socket_path)
        socket = UNIXServer.new(File.join(root, "stale"))
        socket.close
        File.symlink(first.socket_path, File.join(root, "symlink"))
        File.link(first.socket_path, File.join(root, "same-daemon"))
        result = LibTmux::Server.discover(roots: [root, File.dirname(second.socket_path), File.join(root, "missing")], timeout: 2)
        assert_equal [first.daemon_pid, second.daemon_pid].sort, result.servers.map(&:pid).sort
        %i[symlink duplicate_socket probe_failed root_failed].each { |reason| assert_includes result.diagnostics.map { |entry| entry[:reason] }, reason }
        refute result.truncated?
        bounded = LibTmux::Server.discover(roots: [root], max_entries: 1)
        assert bounded.truncated?
        assert_empty bounded.servers
        assert_equal :entry_bound, bounded.diagnostics.last[:reason]
        assert File.socket?(File.join(root, "stale"))
      end
    end
  end

  def test_server_find_or_create_keeps_reused_server_borrowed_and_cleans_new_server
    Dir.mktmpdir("libtmux-ruby-find-server-") do |root|
      endpoint = LibTmux::Endpoint.new(socket_path: File.join(root, "socket"))
      first = LibTmux::Server.find_or_create(endpoint: endpoint)
      second = LibTmux::Server.find_or_create(endpoint: endpoint)
      assert first.created?
      refute second.created?
      second.resource.close
      assert first.resource.display("alive").success?
      pid = first.owner.receipt.pid
      first.owner.close
      assert first.owner.closed?
      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      refute File.exist?(endpoint.socket_path)
    ensure
      first&.resource&.close
      second&.resource&.close
    end
  end

  def test_replacement_daemon_survives_stale_route_and_simulated_numeric_collision
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |old|
        old_owner = old.adopt
        previous_socket = File.stat(fixture.socket_path)
        old.kill
        assert fixture.instance_variable_get(:@server).last.wait_observed(0.5)
        if File.exist?(fixture.socket_path)
          assert_equal [previous_socket.dev, previous_socket.ino], File.stat(fixture.socket_path).then { |stat| [stat.dev, stat.ino] }
          File.unlink(fixture.socket_path)
        end
        endpoint = LibTmux::Endpoint.new(socket_path: fixture.socket_path)
        LibTmux::Server.start(endpoint: endpoint) do |replacement|
          session = replacement.owned_session(name: "replacement", command: ["cat"])
          window = session.resource.owned_window(name: "replacement", command: ["cat"])
          pane = window.resource.owned_pane(direction: :horizontal, command: ["cat"])
          assert_raises(LibTmux::CommandError) { old_owner.close }
          [replacement.adopt, session, window, pane].each do |fresh|
            prior = fresh.receipt
            collision = LibTmux::OwnershipReceipt.__send__(:new, kind: prior.kind, id: prior.id,
              pid: prior.pid, started_at: prior.started_at, generation: old_owner.receipt.generation)
            stale = LibTmux::OwnedResource.__send__(:new, fresh.resource, collision)
            assert_raises(LibTmux::TargetNotFoundError) { stale.close }
          end
          assert_includes replacement.list_panes.map(&:id), pane.resource.id
        end
      end
    end
  end

  def test_cancellation_at_receipt_handoff_rolls_back_and_preserves_exception
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        failure = Interrupt.new("handoff cancelled")
        original = server.method(:owner_from_output)
        server.define_singleton_method(:owner_from_output) do |*arguments|
          owner = original.call(*arguments)
          Thread.current.raise(failure)
          owner
        end
        assert_same failure, assert_raises(Interrupt) { server.owned_session(name: "cancelled", command: ["cat"]) }
        assert_equal ["$0"], server.list_sessions.map(&:id)
      end
    end
  end

  def test_cancellation_token_after_creation_is_rolled_back
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        cancel = LibTmux::Cancellation.new
        original = server.method(:owner_from_output)
        server.define_singleton_method(:owner_from_output) do |*arguments|
          owner = original.call(*arguments)
          cancel.cancel
          owner
        end
        assert_raises(LibTmux::Cancelled) { server.owned_session(name: "cancelled", command: ["cat"], cancel: cancel) }
        assert_equal ["$0"], server.list_sessions.map(&:id)
      ensure
        cancel&.close
      end
    end
  end

  def test_receipt_and_later_pane_identity_failures_expose_retryable_owner
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        window = server.list_windows.first
        before = window.list_panes.map(&:id)
        original = server.method(:lifecycle_value)
        body = RuntimeError.new("identity verification failed")
        server.define_singleton_method(:lifecycle_value) do |entity, field, **options|
          raise body unless before.include?(entity.id)
          original.call(entity, field, **options)
        end
        assert_same body, assert_raises(RuntimeError) { window.find_or_create_pane(identity: "worker", direction: :horizontal, command: ["cat"]) }
        assert_equal before, window.list_panes.map(&:id)
        cleanup = IOError.new("rollback failed")
        destroy = server.method(:destroy_owned)
        server.define_singleton_method(:destroy_owned) { |*, **| raise cleanup }
        failure = assert_raises(LibTmux::CleanupError) { window.find_or_create_pane(identity: "worker", direction: :horizontal, command: ["cat"]) }
        assert_same body, failure.body_error
        assert_same cleanup, failure.cleanup_error
        refute failure.recovery.closed?
        server.define_singleton_method(:destroy_owned, destroy)
        failure.recovery.close
        assert_equal before, window.list_panes.map(&:id)
      end
    end
  end

  def test_uncertain_creation_receipt_does_not_guess_an_owned_object
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        original = server.method(:lifecycle_execute)
        server.define_singleton_method(:lifecycle_execute) do |*arguments|
          result = original.call(*arguments)
          LibTmux::CommandResult.new(stdout: "lost receipt\n", stderr: result.stderr, status: result.status,
            elapsed_seconds: result.elapsed_seconds, pid: result.pid, argv: result.argv)
        end
        failure = assert_raises(LibTmux::OutcomeUnknown) { server.owned_session(name: "unknown", command: ["cat"]) }
        assert_equal :possibly_sent, failure.delivery
        assert_equal 2, server.list_sessions.length
      end
    end
  end

  def test_literal_names_and_identity_survive_format_metacharacters_and_transport_escaping
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        name = "literal-λ-\#{pid}-comma,quote'back\\slash"
        assert_raises(ArgumentError) { server.find_or_create_session(name: name, command: ["cat"]) }
        session_name = name.delete("\\")
        session = server.find_or_create_session(name: session_name, command: ["cat"])
        refute server.find_or_create_session(name: session_name, command: ["cat"]).created?
        assert_raises(ArgumentError) { session.resource.find_or_create_window(name: name, command: ["cat"]) }
        window = session.resource.find_or_create_window(name: session_name, command: ["cat"])
        refute session.resource.find_or_create_window(name: session_name, command: ["cat"]).created?
        identity = "identity-λ\tline\n\#{pid}\\"
        pane = window.resource.find_or_create_pane(identity: identity, direction: :horizontal, command: ["cat"])
        refute window.resource.find_or_create_pane(identity: identity, direction: :horizontal, command: ["cat"]).created?
        assert pane.created?
        session.owner.close
      end
    end
  end

  def test_concurrent_windows_and_panes_reuse_one_creation
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        session = server.list_sessions.first
        windows = 3.times.map { Thread.new { session.find_or_create_window(name: "parallel", command: ["cat"]) } }.map(&:value)
        assert_equal 1, windows.count(&:created?)
        window = windows.first.resource
        panes = 3.times.map { Thread.new { window.find_or_create_pane(identity: "parallel", direction: :horizontal, command: ["cat"]) } }.map(&:value)
        assert_equal 1, panes.count(&:created?)
        windows.find(&:created?).owner.close
      end
    end
  end

  def test_concurrent_servers_publish_one_owned_daemon
    Dir.mktmpdir("libtmux-ruby-concurrent-server-") do |root|
      endpoint = LibTmux::Endpoint.new(socket_path: File.join(root, "socket"))
      workers = 3.times.map { Thread.new { LibTmux::Server.find_or_create(endpoint: endpoint) } }
      workers.each(&:join)
      results = workers.map(&:value)
      assert_equal 1, results.count(&:created?)
      assert_equal 1, results.map { |entry| entry.resource.display("\#{pid}").stdout }.uniq.length
    ensure
      results&.each { |entry| entry.resource.close unless entry.created? }
      results&.find(&:created?)&.owner&.close
    end
  end

  def test_server_owner_retries_local_cleanup_after_confirmed_daemon_destruction
    Dir.mktmpdir("libtmux-ruby-owner-retry-") do |root|
      endpoint = LibTmux::Endpoint.new(socket_path: File.join(root, "socket"))
      result = LibTmux::Server.find_or_create(endpoint: endpoint)
      server = result.resource
      original = server.method(:close)
      cleanup = IOError.new("local cleanup")
      attempts = 0
      server.define_singleton_method(:close) do
        attempts += 1
        raise cleanup if attempts == 1
        original.call
      end
      assert_same cleanup, assert_raises(IOError) { result.owner.close }
      refute result.owner.closed?
      result.owner.close
      assert result.owner.closed?
      assert_equal 2, attempts
    ensure
      result&.resource&.close
    end
  end
end
