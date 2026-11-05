# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"
require "libtmux/async"

# The Async classes subclass blocking core classes but replace their
# constructors, so a class method they inherit, written against the core
# constructor, cannot build one.
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

  def test_discovery_skips_error_classes_and_inherited_constructors
    namespace = Module.new
    namespace.const_set(:Failure, Class.new(LibTmux::UnsupportedFeatureError) { def initialize(message = nil) = super })
    namespace.const_set(:Alias, Class.new(LibTmux::Server))
    namespace.const_set(:Facade, Class.new(LibTmux::Server) { def initialize(scope) = @scope = scope })
    assert_equal [namespace::Facade], self.class.facades(namespace)
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
end
