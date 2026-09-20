# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../gems/libtmux/lib/libtmux/metadata"

class MetadataTest < Minitest::Test
  def test_decodes_binary_lengths_before_recognizing_row_boundaries
    wire = "0:6:雪☃1:\xff\n3:a\nb4:%end0:\n".b
    records = LibTmux::Internal::Metadata.decode(wire, fields: 3)
    assert_equal [["".b, "雪☃".b, "\xff".b], ["a\nb".b, "%end".b, "".b]], records
    wire.replace("changed")
    assert_equal "雪☃".b, records.first[1]
    assert records.frozen?
    assert records.first.frozen?
    assert records.first[1].frozen?
    assert_equal Encoding::BINARY, records.first[1].encoding
    assert_empty LibTmux::Internal::Metadata.decode("".b, fields: 3)
  end

  def test_rejects_malformed_truncated_and_oversized_records
    ["x:a\n", ":a\n", "1a\n", "2:a", "1:a", "1:aX", "1:a\nX",
     "999999999999:a\n", "-1:a\n"].each do |wire|
      error = assert_raises(LibTmux::ProtocolError) do
        LibTmux::Internal::Metadata.decode(wire.b, fields: 1)
      end
      assert_equal :decode, error.phase
      refute_includes error.message, wire
    end
    assert_raises(LibTmux::CapacityError) do
      LibTmux::Internal::Metadata.decode("2:ab\n", fields: 1, max_field_bytes: 1)
    end
    assert_raises(LibTmux::CapacityError) do
      LibTmux::Internal::Metadata.decode("0:\n0:\n", fields: 1, max_rows: 1)
    end
    assert_raises(LibTmux::CapacityError) do
      LibTmux::Internal::Metadata.decode("0:\n", fields: 1, max_bytes: 2)
    end
    assert_raises(LibTmux::ProtocolError) do
      LibTmux::Internal::Metadata.decode("1:\\777\n", fields: 1, quoted: true)
    end
  end
end
