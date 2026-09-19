# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux/control"

class ControlTest < Minitest::Test
  def test_incremental_guard_body_stays_bytes_and_protocol_looking_payload_is_data
    parser = LibTmux::Internal::ControlParser.new(max_line_bytes: 256, max_frame_bytes: 1024)
    wire = "%begin 7 2 1\n%output %1 fake\n%end 7 99 1\n\xff\n%end 7 2 1\n%output %1 a\\000\\377\\134\n".b
    records = []
    wire.each_byte { |byte| parser.feed(byte.chr.b) { |record| records << record } }
    parser.finish
    block, event = records
    assert_equal [7, 2, 1], block.guard
    assert_equal "%output %1 fake\n%end 7 99 1\n\xff\n".b, block.body
    assert_equal :end, block.terminator
    assert_equal wire.byteslice(0, wire.index("%output %1 a")), block.raw
    assert_equal "a\x00\xff\\".b, event.data
    assert_equal "%1", event.pane_id
    assert block.body.frozen?
    assert event.raw.frozen?
    refute_includes block.inspect, "fake"
    refute_includes event.inspect, "\\000"
  end

  def test_extended_output_preserves_unknown_header_fields_and_pause_signals_loss
    parser = LibTmux::Internal::ControlParser.new
    records = []
    wire = "%extended-output %2 19 future : a\\303\\251\n%pause %2\n%continue %2\n%new-notification opaque\n".b
    parser.feed(wire) { |record| records << record }
    assert_equal "a\xc3\xa9".b, records.first.data
    assert_equal wire.lines.first, records.first.raw
    assert_equal [:output, :gap, :gap, :notice], records.map(&:kind)
    assert_equal [:pause, :resume], records[1, 2].map(&:reason)
    assert_equal ["%2", "%2"], records[1, 2].map(&:pane_id)
    assert records[1, 2].all? { |event| event.dropped_bytes.nil? && event.lost_sequences.nil? }

    stream = LibTmux::ControlSubscription.new(pane_id: "%2")
    unrelated = LibTmux::ControlSubscription.new(pane_id: "%3")
    records.each { |record| stream.send(:publish, record); unrelated.send(:publish, record) }
    assert_equal [:output, :gap, :gap], 3.times.map { stream.next(timeout: 0).kind }
    assert_raises(LibTmux::DeadlineExceeded) { unrelated.next(timeout: 0) }
  ensure
    stream&.close
    unrelated&.close
  end

  def test_each_preserves_stop_iteration_raised_by_consumer
    stream = LibTmux::ControlSubscription.new
    stream.send(:publish, LibTmux::ControlEvent.new(kind: :notice, raw: "event"))
    error = StopIteration.new("consumer failure")
    assert_same error, assert_raises(StopIteration) { stream.each { raise error } }
  ensure
    stream&.close
  end

  def test_observed_native_flow_gap_is_not_duplicated_at_the_request_boundary
    control = LibTmux::ControlConnection.allocate
    control.send(:initialize_state, binding_key: "binding", session_id: "$0")
    wake_reader, wake_writer = IO.pipe
    control.instance_variable_set(:@wake_writer, wake_writer)
    request = control.send(:admit, "refresh-client -A '%0:pause'", nil, flow: ["%0", :pause])
    request.offset = request.wire.bytesize
    control.instance_variable_set(:@active, request)
    parser = LibTmux::Internal::ControlParser.new
    parser.feed("%pause %0\n") { |record| control.send(:receive, record) }
    reply = LibTmux::GuardedReply.new(request_id: request.id, blocks: [], generation: control.generation)
    control.send(:complete, request, result: reply)
    gap = control.events.next(timeout: 0)
    assert_equal :pause, gap.reason
    assert_nil gap.dropped_bytes
    assert_raises(LibTmux::DeadlineExceeded) { control.events.next(timeout: 0) }
  ensure
    [wake_reader, wake_writer, request&.reader, request&.writer].compact.each(&:close)
    control&.events&.close
  end

  def test_scope_preserves_original_failure_and_attaches_cleanup_diagnostics
    connection = Object.new
    connection.define_singleton_method(:close) { raise LibTmux::TransportError, "cleanup injection" }
    factory = Class.new(LibTmux::ControlConnection)
    factory.define_singleton_method(:new) { |**_| connection }
    original = RuntimeError.new("original consumer failure")
    assert_same original, assert_raises(RuntimeError) { factory.open { raise original } }
    assert_equal ["control cleanup failed (LibTmux::TransportError)"], original.control_cleanup_errors
  end

  def test_malformed_or_unbounded_stream_fails_closed
    ["%end 1 1 1\n", "%output %1 \\400\n", "%output %1 \\x\n", "%pause invalid\n", "%continue %1 trailing\n"].each do |wire|
      parser = LibTmux::Internal::ControlParser.new
      assert_raises(LibTmux::ProtocolError) { parser.feed(wire) {} }
    end
    parser = LibTmux::Internal::ControlParser.new(max_line_bytes: 8)
    assert_raises(LibTmux::CapacityError) { parser.feed("x" * 9) {} }
    parser = LibTmux::Internal::ControlParser.new(max_frame_bytes: 40)
    assert_raises(LibTmux::CapacityError) { parser.feed("%begin 1 1 1\n" + "abc\n" * 9) {} }
    parser = LibTmux::Internal::ControlParser.new
    parser.feed("%begin 1 1 1\npartial") {}
    assert_raises(LibTmux::ProtocolError) { parser.finish }
  end

  def test_reliable_overflow_preserves_prefix_and_tail_reports_gap
    reliable = LibTmux::ControlSubscription.new(max_bytes: 100, max_events: 1)
    tail = LibTmux::ControlSubscription.new(max_bytes: 100, max_events: 1, mode: :tail)
    events = (1..3).map { |seq| LibTmux::ControlEvent.new(kind: :notice, raw: "x".b, sequence: seq, generation: "g") }
    events.each { |event| reliable.send(:publish, event); tail.send(:publish, event) }
    assert_same events.first, reliable.next(timeout: 0)
    error = assert_raises(LibTmux::SubscriptionOverflow) { reliable.next(timeout: 0) }
    assert_equal 2, error.sequence
    gap = tail.next(timeout: 0)
    assert_equal :gap, gap.kind
    assert_equal [1, 2], gap.lost_sequences
    assert_equal 2, gap.dropped_bytes
    assert_same events.last, tail.next(timeout: 0)
    tail.close
    assert_raises(StopIteration) { tail.next(timeout: 0) }
  end
end
