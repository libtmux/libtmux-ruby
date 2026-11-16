# frozen_string_literal: true

require "rbconfig"

module LibTmuxTest
  # A Ruby program that a test writes where it would otherwise write a shell
  # script, to stand in for tmux or to launch another program. The
  # interpreter skips RubyGems and RUBYOPT, which would otherwise load
  # Bundler into every start, so a stand-in answers well inside the deadlines
  # the tests give a real tmux.
  module StubExecutable
    SHEBANG = "#!#{RbConfig.ruby} --disable=gems,rubyopt"

    # Writes the owner-executable script at path and returns path. Each keyword
    # becomes a string constant the body can use, so a test passes paths in
    # without quoting them into source.
    def self.write(path, body, **constants)
      prelude = constants.map { |name, value| "#{name} = #{value.to_s.dump}\n" }.join
      File.write(path, "#{SHEBANG}\n#{prelude}#{body}", perm: 0o700)
      path
    end
  end
end
