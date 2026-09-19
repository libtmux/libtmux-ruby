# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/selection"

class SelectionTest < Minitest::Test
  def test_membership_is_owned_replayable_and_enumerators_are_independent
    source = [1, 2, 3]
    selection = LibTmux::Selection.new(source)
    source.clear
    left, right = selection.each, selection.each
    assert_equal 3, left.size
    assert_equal 1, left.next
    assert_equal 2, left.next
    assert_equal 1, right.next
    assert_equal [1, 2, 3], selection.to_a
    selection.to_a.clear
    assert_equal [1, 2, 3], selection.to_a
    assert_same selection, selection.each { |_value| nil }
    refute selection.respond_to?(:to_ary)
  end

  def test_only_named_filter_methods_preserve_selection
    selection = LibTmux::Selection.new([1, 2, 3])
    %i[select filter find_all reject].each do |method|
      assert_kind_of Enumerator, selection.public_send(method)
      filtered = selection.public_send(method) { |value| value.odd? }
      assert_instance_of LibTmux::Selection, filtered
      assert_equal(method == :reject ? [2] : [1, 3], filtered.to_a)
    end
    assert_equal [2, 4, 6], selection.map { |value| value * 2 }
    assert_instance_of Array, selection.filter_map { |value| value if value.odd? }
    assert_equal [1, 2], selection.first(2)
    assert_equal 1, selection.count(2)
    assert selection.one?(&:even?)
    assert_instance_of Enumerator::Lazy, selection.lazy
  end

  def test_filter_blocks_keep_truthiness_control_flow_and_original_exceptions
    selection = LibTmux::Selection.new([false, nil, 0, ""])
    assert_equal [0, ""], selection.select { |value| value }.to_a
    assert_equal :stopped, selection.select { break :stopped }
    assert_equal :returned, return_from_filter(selection)
    assert_equal :thrown, catch(:halt) { selection.reject { throw :halt, :thrown } }
    error = RuntimeError.new("block failure")
    assert_same error, assert_raises(RuntimeError) { selection.find_all { raise error } }
    visited = []
    result = selection.select do |value|
      visited << value
      next false if value.nil?
      true
    end
    assert_equal [false, nil, 0, ""], visited
    assert_equal [false, 0, ""], result.to_a
  end

  def test_cardinality_counts_occurrences_including_false_and_nil
    empty = LibTmux::Selection.new([])
    assert_raises(LibTmux::NoMatchError) { empty.one }
    assert_nil empty.one_or_nil
    refute empty.exists?
    assert_equal false, LibTmux::Selection.new([false]).one
    assert_nil LibTmux::Selection.new([nil]).one
    assert LibTmux::Selection.new([nil]).exists?
    repeated = LibTmux::Selection.new([false, false])
    assert_raises(LibTmux::MultipleMatchesError) { repeated.one }
    assert_raises(LibTmux::MultipleMatchesError) { repeated.one_or_nil }
  end

  private

  def return_from_filter(selection)
    selection.select { return :returned }
    :incorrect
  end
end
