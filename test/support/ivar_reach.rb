# frozen_string_literal: true

require "prism"
require "set"

module LibTmuxTest
  # Reads method source with Prism to find the instance variables a method
  # reads and the hazards it reaches (blocking calls, and building an object
  # through `self.class`), following self-calls, `__send__(:name)` with a
  # literal symbol, `super`, aliases and attr readers, within LibTmux code.
  # Reads that are safe when the ivar is unset are not counted: `@x ||=`,
  # `@x&.`, reads guarded by `defined?(@x)` or `instance_variable_defined?`,
  # reads of an ivar the same method assigns (`@x += 1` does not count), and
  # an ivar passed straight to a method the walked class overrides (the
  # override decides what nil means).
  # Blind spots: `send` with a computed name, define_method bodies, calls on a
  # receiver other than self (a helper object can still block), blocking APIs
  # missing from the lists below, and instance_variable_set with a computed name.
  class IvarReach
    ATTR = %i[attr_reader attr_accessor].freeze
    SENDERS = %i[__send__ send public_send].freeze
    # `@x += 1` is left out: it reads @x first and fails while @x is unset.
    WRITES = [Prism::InstanceVariableWriteNode, Prism::InstanceVariableTargetNode, Prism::InstanceVariableOrWriteNode,
      Prism::InstanceVariableAndWriteNode].freeze
    READS = [Prism::InstanceVariableReadNode, Prism::InstanceVariableAndWriteNode, Prism::InstanceVariableOperatorWriteNode].freeze
    # Calls that block the calling thread or start a process outside the
    # scheduler-owned executor.
    BLOCKING_CALLS = {Process: %i[spawn fork exec wait waitpid wait2 waitall detach], IO: %i[popen select],
      Thread: %i[new start fork], Kernel: %i[spawn system fork exec]}.freeze
    BLOCKING_SELF_CALLS = %i[spawn system fork exec].freeze
    CLASS_BUILDERS = %w[new open start allocate].freeze
    BLOCKING_CONSTANTS = %i[ProcessExecutor Open3 PTY].freeze
    FILES = {}

    attr_reader :reads, :writes, :hazards

    # Names of the methods walked so far.
    def visited = @seen.map(&:name).uniq

    def initialize(klass)
      @klass = klass
      @reads, @hazards, @writes = {}, {}, Set.new
      @seen, @handed = Set.new, Set.new
    end

    # Walks one method. With only_core, stops at methods the class defines
    # itself, because those override the core bodies that would otherwise run.
    def walk(name, only_core:, owner: nil, path: [])
      method = owner ? owner.instance_method(name) : @klass.instance_method(name)
      return self unless @seen.add?(method) && libtmux?(method.owner)
      return self if only_core && !core?(method.owner)

      path += [name]
      node = definition(method)
      if node.is_a?(Symbol)
        @reads[node] ||= path
      elsif node
        outer, @guarded = @guarded, guarded_ivars(node)
        begin
          visit(node, method.owner, name, only_core, path)
        ensure
          @guarded = outer
        end
      end
      self
    rescue NameError
      self
    end

    # Instance variables the class can have set: everything its initialize
    # reaches (super and core helpers included), what its own methods assign
    # directly, and literal instance_variable_set calls in its source file.
    # When initialize reaches the parent's initialize, the object is a fully
    # built core object, so what core methods assign counts as well.
    def facade_writes
      walk(:initialize, only_core: false)
      owners = [@klass]
      owners.concat(@klass.ancestors.drop(1).select { |mod| core?(mod) }) if @seen.include?(@klass.superclass.instance_method(:initialize))
      owners.each do |owner|
        (owner.instance_methods(false) + owner.private_instance_methods(false)).each do |name|
          node = definition(owner.instance_method(name))
          each_node(node) { |child| @writes << child.name if WRITES.any? { |kind| child.is_a?(kind) } } if node.is_a?(Prism::Node)
        end
      end
      file = @klass.instance_method(:initialize).source_location.first
      each_node(parse(file)) do |child|
        symbol = child.arguments&.arguments&.first if child.is_a?(Prism::CallNode) && child.name == :instance_variable_set
        @writes << symbol.unescaped.to_sym if symbol.is_a?(Prism::SymbolNode)
      end
      @writes
    end

    private

    def parse(file) = FILES[file] ||= Prism.parse_file(file).value

    def each_node(node, &block)
      block.call(node)
      node.compact_child_nodes.each { |child| each_node(child, &block) }
    end

    def core?(mod) = mod.name.to_s.start_with?("LibTmux::") && !mod.name.start_with?("LibTmux::Async::")

    # LibTmux code, or an anonymous class or module (as in this helper's own tests).
    def libtmux?(mod) = mod.name.nil? || mod.name.start_with?("LibTmux")

    # The def node for a method, or the ivar an attr reader returns.
    def definition(method)
      file, line = method.source_location
      return unless file && File.file?(file)

      tree = parse(file)
      find(tree) { |n| n.is_a?(Prism::DefNode) && n.location.start_line == line && n.name == method.original_name } ||
        attr_ivar(tree, method, line)
    end

    def attr_ivar(tree, method, line)
      call = find(tree) { |n| n.is_a?(Prism::CallNode) && ATTR.include?(n.name) && n.location.start_line == line }
      :"@#{method.original_name}" if call&.arguments&.arguments&.any? { |a| a.respond_to?(:unescaped) && a.unescaped.to_sym == method.original_name }
    end

    def find(node, &block)
      return node if block.call(node)

      node.compact_child_nodes.each { |child| (hit = find(child, &block)) && (return hit) }
      nil
    end

    # Ivars a method may read while unset: tested with `defined?` or
    # `instance_variable_defined?`, called through `&.`, or assigned in the
    # same method.
    def guarded_ivars(node)
      guarded = Set.new
      each_node(node) do |child|
        guarded << child.name if WRITES.any? { |kind| child.is_a?(kind) }
        case child
        when Prism::DefinedNode
          each_node(child) { |inner| guarded << inner.name if inner.is_a?(Prism::InstanceVariableReadNode) }
        when Prism::CallNode
          guarded << child.receiver.name if child.safe_navigation? && child.receiver.is_a?(Prism::InstanceVariableReadNode)
          argument = child.arguments&.arguments&.first
          if child.name == :instance_variable_defined? && argument.is_a?(Prism::SymbolNode)
            guarded << argument.unescaped.to_sym
          end
        end
      end
      guarded
    end

    def visit(node, home, method_name, only_core, path)
      if READS.any? { |kind| node.is_a?(kind) } && !@guarded.include?(node.name) && !@handed.include?(node.object_id)
        @reads[node.name] ||= path
      end
      @writes << node.name if WRITES.any? { |kind| node.is_a?(kind) }
      case node
      when Prism::CallNode then call(node, only_core, path)
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        @hazards["calls #{node.name}"] ||= path if BLOCKING_CONSTANTS.include?(node.name)
      when Prism::XStringNode, Prism::InterpolatedXStringNode then @hazards["runs a backtick command"] ||= path
      when Prism::SuperNode, Prism::ForwardingSuperNode
        parent = @klass.ancestors.drop_while { |a| a != home }.drop(1)
          .find { |a| a.method_defined?(method_name, false) || a.private_method_defined?(method_name, false) }
        walk(method_name, only_core: only_core, owner: parent, path: path) if parent
      end
      node.compact_child_nodes.each { |child| visit(child, home, method_name, only_core, path) }
    end

    def call(node, only_core, path)
      receiver = node.receiver
      constant = receiver.name if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      if constant && BLOCKING_CALLS.fetch(constant, []).include?(node.name)
        @hazards["calls #{constant}.#{node.name}"] ||= path
      elsif self_receiver?(node) && BLOCKING_SELF_CALLS.include?(node.name)
        @hazards["calls #{node.name}"] ||= path
      elsif (builder = class_builder(node))
        @hazards["builds an object through self.class.#{builder}"] ||= path
      end
      return unless self_receiver?(node)

      if overridden?(node.name)
        node.arguments&.arguments&.each { |argument| @handed << argument.object_id if argument.is_a?(Prism::InstanceVariableReadNode) }
      end
      if SENDERS.include?(node.name)
        target = node.arguments&.arguments&.first
        walk(target.unescaped.to_sym, only_core: only_core, path: path) if target.is_a?(Prism::SymbolNode)
      else
        walk(node.name, only_core: only_core, path: path)
      end
    end

    def self_receiver?(node) = node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

    # True when the method the walked class runs for this name is not core
    # code and replaces an ancestor's definition.
    def overridden?(name)
      method = @klass.instance_method(name)
      !core?(method.owner) && !method.super_method.nil?
    rescue NameError
      false
    end

    # `self.class.new(...)`, `.open`, `.start`, `.allocate`, or the same through
    # `__send__`: the subclass may have a different, private or refused
    # constructor. Returns the builder name, or nil.
    def class_builder(node)
      receiver = node.receiver
      return unless receiver.is_a?(Prism::CallNode) && receiver.name == :class && self_receiver?(receiver)
      return node.name.to_s if CLASS_BUILDERS.include?(node.name.to_s)

      target = node.arguments&.arguments&.first
      target.unescaped if SENDERS.include?(node.name) && target.is_a?(Prism::SymbolNode) && CLASS_BUILDERS.include?(target.unescaped)
    end
  end
end
