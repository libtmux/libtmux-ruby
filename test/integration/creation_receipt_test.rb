# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/tmux_fixture"
require "libtmux"

class CreationReceiptTest < Minitest::Test
  def test_creation_receipts_return_initial_children_in_the_command_reply
    LibTmuxTest::TmuxFixture.open do |fixture|
      LibTmux::Server.open(socket_path: fixture.socket_path) do |server|
        receipt = server.new_session(name: "receipt", command: ["cat"], receipt: true)
        assert_instance_of LibTmux::CreationReceipt, receipt
        assert_instance_of LibTmux::Session, receipt.entity
        assert_equal [receipt.window.ref], receipt.entity.list_windows.map(&:ref)
        assert_equal [receipt.pane.ref], receipt.window.list_panes.map(&:ref)
        assert receipt.result.success?
        assert_equal :observed, receipt.result.delivery
        assert receipt.frozen?
        assert_equal 3, LibTmux::Internal::Metadata.decode(receipt.result.stdout, fields: 3).first.length
        window = receipt.entity.new_window(name: "second", command: ["cat"], receipt: true)
        assert_instance_of LibTmux::Window, window.entity
        assert_same window.entity, window.window
        assert_equal [window.pane.ref], window.window.list_panes.map(&:ref)
        assert_equal 2, LibTmux::Internal::Metadata.decode(window.result.stdout, fields: 2).first.length
        assert_raises(ArgumentError) { server.new_session(name: "invalid", command: ["cat"], receipt: :yes) }
      end
    end
  end
end
