# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"

class NativeGuardTest < Minitest::Test
  def guard
    LibTmux::Internal::NativeGuard
  end

  def release(text)
    LibTmux::Internal::TmuxVersion.parse(text)
  end

  def refused(argv, text, **options)
    error = assert_raises(LibTmux::UnsupportedFeatureError, "#{argv.inspect} on #{text}") do
      guard.check(argv, release(text), **options)
    end
    assert_equal [:not_sent, :admission], [error.delivery, error.phase]
    error
  end

  def allowed(argv, text, **options)
    assert_nil guard.check(argv, release(text), **options), "#{argv.inspect} on #{text}"
  end

  def test_named_buffer_deletion_and_rename_need_tmux_3_4
    ["3.3a"].each do |text|
      refused(%w[delete-buffer -b saved], text)
      refused(%w[deleteb -b saved], text)
      refused(%w[delete-b -bsaved], text)
      refused(%w[set-buffer -b saved -n renamed], text)
      refused(%w[setb -n renamed -b saved], text)
      refused(%w[set-b -b saved -n renamed], text)
    end
    %w[3.4 3.7d next-3.9].each do |text|
      allowed(%w[delete-buffer -b saved], text)
      allowed(%w[set-buffer -b saved -n renamed], text)
    end
  end

  def test_buffer_forms_that_do_not_name_a_buffer_stay_available
    allowed(%w[delete-buffer], "3.3a")
    allowed(%w[set-buffer -b saved data], "3.3a")
    allowed(%w[set-buffer -a data], "3.3a")
    allowed(%w[paste-buffer -d -b saved -t %0], "3.3a")
    allowed(%w[load-buffer -b saved -], "3.3a")
    allowed(%w[set-option -g @name delete-buffer], "3.3a")
  end

  def test_batches_are_read_item_by_item
    refused(["set-option", "-g", "@a", "1", ";", "delete-buffer", "-b", "saved"], "3.3a")
    refused(["set-option", "-g", "@a", "1;", "delete-buffer", "-b", "saved"], "3.3a")
    allowed(["set-option", "-g", "@a", "1\;", "delete-buffer"], "3.3a")
    allowed(["set-option", "-g", "@a", "x ; delete-buffer -b saved"], "3.3a")
    allowed(["display-message", "-p", "--", "delete-buffer"], "3.3a")
  end

  def test_exact_tmux_3_7_refuses_raw_break_pane_but_not_the_repaired_call
    refused(%w[break-pane -d -s %1], "3.7")
    refused(%w[breakp -d -n named -s %1], "3.7")
    refused(%w[break-pane -d -n named -s %1], "3.7", repaired_break: false)
    refused(%w[break-pane -d -s %1], "3.7", repaired_break: true)
    allowed(%w[break-pane -d -n named -s %1], "3.7", repaired_break: true)
    %w[3.6b 3.7a 3.7d 3.8 next-3.9].each { |text| allowed(%w[break-pane -d -s %1], text) }
  end

  def test_split_window_percent_flag_is_refused_on_tmux_3_4_only
    refused(%w[split-window -d -p 30 -t %0], "3.4")
    refused(%w[splitw -dp30], "3.4")
    %w[3.3a 3.5 3.7d].each { |text| allowed(%w[split-window -d -p 30 -t %0], text) }
    allowed(%w[split-window -d -l 30% -t %0], "3.4")
  end

  def test_malformed_layouts_are_refused_before_tmux_3_4
    refused(%w[select-layout -t %0 garbage], "3.3a")
    refused(%w[selectl abc], "3.3a")
    refused(%w[select-layout -o tiled], "3.3a")
    allowed(%w[select-layout -t %0 tiled], "3.3a")
    allowed(%w[select-layout -t %0 even-h], "3.3a")
    allowed(%w[select-layout -t %0 b25d,80x24,0,0,0], "3.3a")
    allowed(%w[select-layout -t %0], "3.3a")
    allowed(%w[select-layout -E -t %0], "3.3a")
    allowed(%w[select-layout -t %0 garbage], "3.4")
  end

  def test_ambiguous_and_unknown_commands_are_not_guessed
    allowed(%w[set -b saved -n x], "3.3a")
    allowed(%w[no-such-command -b saved], "3.3a")
    allowed(["select-layout"], "3.3a")
  end
end
