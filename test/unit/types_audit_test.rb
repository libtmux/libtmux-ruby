# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

# Each scripts/types audit rule, shown failing `audit!` on a class planted in
# LibTmux.
class TypesAuditTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    load File.join(ROOT, "scripts/types") unless defined?(PublicAPI)
  end

  def test_a_factory_inherited_by_a_subclass_with_its_own_constructor_fails
    errors = audit_errors(<<~RUBY, <<~RBS)
      module LibTmux
        class AuditProbeBase
          def self.build(**options) = new(**options)
          def initialize(**); end
        end

        class AuditProbeLeaf < AuditProbeBase
          def initialize(scope); end
        end
      end
    RUBY
      module LibTmux
        class AuditProbeBase
          def self.build: (**untyped) -> instance
          def initialize: (**untyped) -> void
        end

        class AuditProbeLeaf < AuditProbeBase
          def initialize: (untyped) -> void
        end
      end
    RBS
    assert_includes errors, "inherited factory not overridden: LibTmux::AuditProbeLeaf.build"
  end

  def test_a_factory_from_an_extended_module_fails
    errors = audit_errors(<<~RUBY, <<~RBS)
      module LibTmux
        module AuditProbeFactory
          def build(**options) = new(**options)
        end

        class AuditProbeBase
          extend AuditProbeFactory
          def initialize(**); end
        end

        class AuditProbeLeaf < AuditProbeBase
          def initialize(scope); end
        end
      end
    RUBY
      module LibTmux
        module AuditProbeFactory
          def build: (**untyped) -> untyped
        end

        class AuditProbeBase
          extend AuditProbeFactory
          def initialize: (**untyped) -> void
        end

        class AuditProbeLeaf < AuditProbeBase
          def initialize: (untyped) -> void
        end
      end
    RBS
    assert_includes errors, "inherited factory not overridden: LibTmux::AuditProbeLeaf.build"
  end

  def test_a_public_declaration_the_runtime_lacks_fails
    errors = audit_errors(<<~RUBY, <<~RBS)
      module LibTmux
        class AuditProbeGhost
          def self.build = new
          private_class_method def self.hidden = nil
        end
      end
    RUBY
      module LibTmux
        class AuditProbeGhost
          def self.build: () -> instance
          def self.hidden: () -> nil
          def self.ghost: () -> void
        end
      end
    RBS
    assert_includes errors, "declared public but not callable: LibTmux::AuditProbeGhost.hidden"
    assert_includes errors, "declared public but not callable: LibTmux::AuditProbeGhost.ghost"
  end

  def test_an_export_without_a_declaration_fails
    error = assert_raises(PublicAPI::Error) do
      planted("module LibTmux; class AuditProbeBare; end; end", "") { |api| api.audit! }
    end
    assert_equal "missing RBS declaration: LibTmux::AuditProbeBare", error.message
  end

  private

  # The lines `audit!` raises for the planted classes.
  def audit_errors(ruby, rbs)
    planted(ruby, rbs) { |api| assert_raises(PublicAPI::Error) { api.audit! } }.message.lines(chomp: true)
  end

  # Defines the Ruby source inside LibTmux, declares the RBS beside the
  # shipped signatures, yields a fresh inventory, then removes the classes.
  def planted(ruby, rbs)
    before = LibTmux.constants
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "probe.rbs"), rbs)
      TOPLEVEL_BINDING.eval(ruby)
      yield PublicAPI.new(signatures: [dir])
    end
  ensure
    (LibTmux.constants - before).each { |name| LibTmux.__send__(:remove_const, name) }
  end
end
