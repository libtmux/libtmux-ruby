# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/ivar_reach"
require "libtmux"
require "libtmux/async"

# The Async classes subclass blocking core classes but replace their
# constructors. A class method they inherit was written against the core
# constructor, and an instance method they inherit runs core code against
# the facade's state, so both surfaces are checked here.
class AsyncSurfaceTest < Minitest::Test
  # Classes in the namespace that subclass a core class and replace its
  # constructor. An error class keeps the core constructor and public `new`.
  def self.facades(namespace)
    namespace.constants.map { |name| namespace.const_get(name) }.grep(Class).select do |klass|
      klass.superclass.name.to_s.start_with?("LibTmux::") && !klass.superclass.name.start_with?("LibTmux::Async") &&
        !(klass < Exception) && klass.instance_method(:initialize).owner != klass.superclass.instance_method(:initialize).owner
    end
  end

  CLASSES = facades(LibTmux::Async).freeze
  REFUSED = {LibTmux::Async::Server => %i[start open]}.freeze
  HOOKS = %i[run dispatch ensure_owner ensure_open].freeze
  # Core helpers no facade path reaches. Server: core dispatch and
  # Terminal#attach call them, and the facade overrides both.
  # ControlConnection: the core reader thread's loop and cleanup, which only
  # the core initialize starts; the Async connection runs its scope's driver.
  UNREACHABLE = {
    LibTmux::Async::Server => %i[perform_request retire_request],
    LibTmux::Async::ControlConnection => %i[run cleanup]
  }.freeze

  def test_class_level_surface_is_owned_or_refused
    CLASSES.each do |klass|
      names = klass.singleton_methods - Object.singleton_methods
      owners = names.sort.map { |name| "#{name} from #{klass.method(name).owner}" }.join(", ")
      assert_equal REFUSED.fetch(klass, []).sort, names.sort, "#{klass} class-level surface: #{owners}"
      names.each do |name|
        assert_equal klass.singleton_class, klass.method(name).owner, "#{klass}.#{name} is inherited"
        error = assert_raises(LibTmux::UnsupportedFeatureError) { klass.public_send(name) }
        assert_equal :admission, error.phase
      end
    end
  end

  # Core code the facade runs, whether through an inherited method, a super
  # call in an override, a core helper an override calls, or a private
  # helper that entities call on their server, must not read state the
  # facade never builds (Async::Server#initialize does not call super),
  # block the scheduler thread, or build an object through the facade's
  # private constructor. Every LibTmux method on the class is a root.
  def test_code_the_facade_runs_reaches_only_state_it_builds
    problems = CLASSES.flat_map do |klass|
      set = LibTmuxTest::IvarReach.new(klass).facade_writes
      (method_names(klass) - UNREACHABLE.fetch(klass, [])).flat_map do |name|
        reach = LibTmuxTest::IvarReach.new(klass).walk(name, only_core: false)
        unset = reach.reads.reject { |ivar, _| set.include?(ivar) }.map do |ivar, path|
          "#{klass}##{name} reads #{ivar} via #{path.join(' -> ')}, which #{klass} never sets"
        end
        unset + reach.hazards.map { |hazard, path| "#{klass}##{name} #{hazard} via #{path.join(' -> ')}" }
      end
    end
    assert_empty problems, "code the facade runs reaches state or blocking calls the facade does not provide. " \
      "A core helper that no facade path calls belongs in UNREACHABLE."
  end

  def test_unreachable_helpers_stay_unreachable
    UNREACHABLE.each do |klass, names|
      reach = LibTmuxTest::IvarReach.new(klass)
      (method_names(klass) - names).each { |name| reach.walk(name, only_core: false) }
      assert_empty names & reach.visited, "#{klass} reaches a helper listed as unreachable"
      names.each { |name| assert klass.private_method_defined?(name), "#{klass}##{name} no longer exists" }
    end
  end

  def test_the_reach_check_sees_planted_reads_and_blocking_calls
    core = Class.new do
      def initialize = @kept = 1
      def public_one = helper
      def public_two = @kept
      def public_three = Process.spawn("true")
      def memoized = (@memo ||= {}).dup
      def guarded = defined?(@maybe) ? @maybe : 0
      def local = (@buffer = []) && @buffer.length
      def leaks = (guard_elsewhere; @lost.length)
      def hands_over = notify(@unset)
      def hands_elsewhere = report(@unset)
      private def notify(value) = value
      private def report(value) = value
      def copy = self.class.open
      def sends = __send__(:helper)
      def counts = @count += 1
      def checked = instance_variable_defined?(:@maybe) ? @maybe : 0
      def shells = system("true")
      def threads = Thread.new {}
      def pipes = IO.popen("true")
      def captures = Open3.capture2("true")
      def terminals = PTY.spawn("true")
      def allocates = self.class.allocate
      def sends_new = self.class.__send__(:new)
      attr_reader :exposed
      alias_method :renamed, :public_one
      private def guard_elsewhere = defined?(@lost)
      private def helper = @lost.length
    end
    facade = Class.new(core) do
      def initialize = @own = 1
      def tally = @ticks += 1
      private def notify(value) = value&.to_s
    end
    reads = LibTmuxTest::IvarReach.new(facade).walk(:public_one, only_core: false).reads
    assert_equal({:@lost => %i[public_one helper]}, reads)
    assert_equal({"calls Process.spawn" => %i[public_three]}, LibTmuxTest::IvarReach.new(facade).walk(:public_three, only_core: false).hazards)
    %i[memoized guarded local].each { |name| assert_empty LibTmuxTest::IvarReach.new(facade).walk(name, only_core: false).reads, name }
    assert_equal [:@lost], LibTmuxTest::IvarReach.new(facade).walk(:leaks, only_core: false).reads.keys
    assert_equal [:@lost], LibTmuxTest::IvarReach.new(facade).walk(:renamed, only_core: false).reads.keys
    assert_empty LibTmuxTest::IvarReach.new(facade).walk(:hands_over, only_core: false).reads
    assert_equal [:@unset], LibTmuxTest::IvarReach.new(facade).walk(:hands_elsewhere, only_core: false).reads.keys
    assert_equal ["builds an object through self.class.open"], LibTmuxTest::IvarReach.new(facade).walk(:copy, only_core: false).hazards.keys
    assert_equal [:@lost], LibTmuxTest::IvarReach.new(facade).walk(:sends, only_core: false).reads.keys
    assert_equal [:@count], LibTmuxTest::IvarReach.new(facade).walk(:counts, only_core: false).reads.keys
    assert_equal [:@exposed], LibTmuxTest::IvarReach.new(facade).walk(:exposed, only_core: false).reads.keys
    assert_empty LibTmuxTest::IvarReach.new(facade).walk(:checked, only_core: false).reads
    {shells: "calls system", threads: "calls Thread.new", pipes: "calls IO.popen", captures: "calls Open3",
     terminals: "calls PTY", allocates: "builds an object through self.class.allocate",
     sends_new: "builds an object through self.class.new"}.each do |name, hazard|
      assert_equal [hazard], LibTmuxTest::IvarReach.new(facade).walk(name, only_core: false).hazards.keys, name
    end
    assert_equal [:@own], LibTmuxTest::IvarReach.new(facade).facade_writes.to_a
  end

  def test_discovery_skips_error_classes_and_inherited_constructors
    namespace = Module.new
    namespace.const_set(:Failure, Class.new(LibTmux::UnsupportedFeatureError) { def initialize(message = nil) = super })
    namespace.const_set(:Alias, Class.new(LibTmux::Server))
    namespace.const_set(:Facade, Class.new(LibTmux::Server) { def initialize(scope) = @scope = scope })
    assert_equal [namespace::Facade], self.class.facades(namespace)
  end

  def test_facade_overrides_the_transport_hooks_inherited_methods_rely_on
    HOOKS.each do |name|
      assert_equal LibTmux::Async::Server, LibTmux::Async::Server.instance_method(name).owner,
        "Async::Server##{name} falls through to the core"
    end
  end

  def test_library_built_constructors_are_private
    CLASSES.each do |klass|
      refute_respond_to klass, :new
      assert_raises(NoMethodError) { klass.new }
    end
  end

  def test_facade_requires_a_scope
    assert_raises(ArgumentError) { LibTmux::Async::Server.__send__(:new, nil, LibTmux::Server.allocate) }
  end

  def test_facade_attach_is_refused
    facade = LibTmux::Async::Server.allocate
    error = assert_raises(LibTmux::UnsupportedFeatureError) { facade.attach(session: nil, terminal: $stdout, term: "xterm") }
    assert_equal :admission, error.phase
  end

  private

  # Every instance method the class runs, of any visibility; the walk skips
  # methods that are not LibTmux code.
  def method_names(klass)
    (klass.instance_methods + klass.private_instance_methods).uniq
  end
end
