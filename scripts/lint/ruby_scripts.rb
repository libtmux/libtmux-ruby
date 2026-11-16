# frozen_string_literal: true

# Finds the Ruby scripts under scripts/ by extension or shebang, so a new one
# needs no entry in scripts/check or scripts/lint/lint.
module RubyScripts
  SHEBANG = "#!/usr/bin/env ruby"

  def self.find(root)
    Dir.chdir(root) do
      Dir["scripts/**/*"].select do |path|
        File.file?(path) && (path.end_with?(".rb") || File.open(path, &:gets).to_s.start_with?(SHEBANG))
      end.sort
    end
  end
end
