# frozen_string_literal: true

require "shellwords"

module LibTmuxTest
  # Reads the fenced blocks of the repository's READMEs and lints what they
  # promise, so a test can run the commands and links the pages show.
  module ReadmeBlocks
    ROOT = File.expand_path("../..", __dir__)
    GEMS = %w[libtmux libtmux-async libtmux-mcp libtmux-workspace].freeze
    DOCUMENTS = (["README.md"] + GEMS.map { |name| "gems/#{name}/README.md" }).freeze
    GEM_TREE = "https://github.com/libtmux/libtmux-ruby/tree/master/gems"
    TOOL_PAGES = "https://libtmux.org/en/ruby/latest/mcp/tools"

    Fence = Struct.new(:language, :lines, :line)
    Step = Struct.new(:command, :line, :output)

    module_function

    def read(path)
      File.read(File.join(ROOT, path))
    end

    def fences(markdown)
      found = []
      open = nil
      markdown.each_line.with_index(1) do |text, number|
        line = text.chomp
        if open
          if line.match?(/\A```\s*\z/)
            found << open
            open = nil
          else
            open.lines << line
          end
        elsif (match = line.match(/\A```(\S*)\s*\z/))
          open = Fence.new(match[1], [], number)
        end
      end
      raise ArgumentError, "unterminated code fence opened at line #{open.line}" if open

      found
    end

    # One command per console block, as WRITING.md requires. A `text` block
    # that follows a console block is the output of its command.
    def steps(markdown)
      blocks = fences(markdown)
      blocks.each_with_index.filter_map do |fence, index|
        next unless fence.language == "console"

        following = blocks[index + 1]
        output = following.lines.join("\n") + "\n" if following&.language == "text"
        Step.new(command(fence), fence.line, output)
      end
    end

    def command(fence)
      words = []
      continued = false
      fence.lines.each do |line|
        if continued
          words << line.strip
        elsif line.start_with?("$ ") && words.empty?
          words << line.delete_prefix("$ ")
        else
          raise ArgumentError, "console block at line #{fence.line} holds more than one command or its output"
        end
        continued = line.end_with?("\\")
        words[-1] = words[-1].delete_suffix("\\").strip if continued
      end
      raise ArgumentError, "console block at line #{fence.line} is empty" if words.empty?
      raise ArgumentError, "console block at line #{fence.line} ends in a continuation" if continued

      words.join(" ")
    end

    def words(command)
      Shellwords.split(command)
    rescue ArgumentError
      []
    end

    # Every console block holds exactly one command.
    def console_problems(markdown, path)
      fences(markdown).filter_map do |fence|
        next unless fence.language == "console"

        command(fence)
        nil
      rescue ArgumentError => error
        "#{path}: #{error.message}"
      end
    end

    # A tool named in a table row or list item links to its page on libtmux.org;
    # a link to a tool page names the tool it shows. A reference-style link is
    # followed to its definition.
    def tool_link_problems(markdown, path, tools:)
      definitions = reference_definitions(markdown)
      linked = /\[`(tmux_[a-z_]+)`\](?:\(([^)]*)\)|\[([^\]]*)\])/
      problems = []
      markdown.each_line.with_index(1) do |line, number|
        line.scan(linked) do |name, target, label|
          if label
            target = definitions[label]
            unless target
              problems << "#{path}:#{number}: #{name} uses the undefined link label #{label}"
              next
            end
          end
          expected = "#{TOOL_PAGES}/#{name}/"
          next unless tools.include?(name) || target.start_with?("#{TOOL_PAGES}/")

          problems << "#{path}:#{number}: #{name} links to #{target}, not #{expected}" unless target == expected
        end
        next unless line.match?(/\A\s*(?:\||[-*] |\d+\. )/)

        stripped = line.gsub(linked, "")
        stripped.scan(/`(tmux_[a-z_]+)`/) do |(name)|
          problems << "#{path}:#{number}: #{name} is not linked to its tool page" if tools.include?(name)
        end
      end
      problems
    end

    # `[label]: target` lines outside code fences.
    def reference_definitions(markdown)
      without_fences(markdown).scan(/^\[([^\]]+)\]:\s+(\S+)\s*$/).to_h
    end

    # The markdown with its fenced blocks removed.
    def without_fences(markdown)
      markdown.gsub(/^```.*?^```[ \t]*$/m, "")
    end

    # Every `[text][label]` names a defined label, and every defined label is
    # used, so a mistyped label cannot render as literal brackets.
    def reference_link_problems(markdown, path)
      defined = reference_definitions(markdown)
      text = without_fences(markdown).lines.reject { |line| line.match?(/^\[[^\]]+\]:\s/) }.join
      used = text.scan(/\]\[([^\]]+)\]/).flatten.uniq
      (used - defined.keys).map { |label| "#{path}: the link label [#{label}] has no definition" } +
        (defined.keys - used).map { |label| "#{path}: the link definition [#{label}] is not used" }
    end

    # The id a heading gets, as scripts/docs and GitHub compute it.
    def heading_anchors(markdown)
      seen = Hash.new(0)
      without_fences(markdown).lines.grep(/\A\#{1,6} /).map do |line|
        text = line.sub(/\A\#+ /, "").strip
        text = text.gsub(/\[([^\]]*)\](?:\([^)]*\)|\[[^\]]*\])/, '\1').delete("`")
        id = text.downcase.gsub(/[^\p{Alnum}_\- ]/, "").tr(" ", "-")
        count = seen[id]
        seen[id] += 1
        count.zero? ? id : "#{id}-#{count}"
      end
    end

    # Each `](#anchor)` in the page lands on one of its headings.
    def anchor_problems(markdown, path)
      anchors = heading_anchors(markdown)
      without_fences(markdown).scan(/\]\(#([^)]+)\)/).flatten.uniq.reject { |anchor| anchors.include?(anchor) }
        .map { |anchor| "#{path}: no heading has the anchor ##{anchor}" }
    end

    # Every `--flag` that a command passes to the program, and every one the
    # program's own README names in code, is one the executable prints.
    def flag_problems(markdown, path, program:, help:, prose: false)
      known = help.scan(/(?<![\w-])(--[a-z][a-z0-9-]*)/).flatten.uniq
      mentioned = steps(markdown).flat_map do |step|
        words = words(step.command)
        index = words.first == "gem" ? nil : words.index(program)
        index ? words.drop(index + 1).grep(/\A--[a-z]/).map { |word| word.split("=").first } : []
      end
      mentioned += markdown.scan(/`(--[a-z][a-z0-9-]*)[^`]*`/).flatten if prose
      (mentioned.uniq - known).map { |flag| "#{path}: #{flag} is not an option of #{program}" }
    end

    # `gem install NAME` names a gem this repository builds and passes no --pre:
    # releases are final versions, which a plain install resolves.
    def gem_install_problems(markdown, path, gems:)
      steps(markdown).filter_map do |step|
        words = words(step.command)
        next unless words.first(2) == %w[gem install]
        next if words.include?("--local")

        names = words.drop(2).reject { |word| word.start_with?("-") }
        unknown = names - gems
        next "#{path}:#{step.line}: #{unknown.join(', ')} is not a gem of this repository" unless unknown.empty?
        next "#{path}:#{step.line}: drop --pre, which no release requires" if words.include?("--pre")

        nil
      end
    end

    # The Gem | Require | Use it for table lists every gem and the path to require.
    REQUIRES = {"libtmux" => "libtmux", "libtmux-async" => "libtmux/async", "libtmux-mcp" => "libtmux/mcp",
                "libtmux-workspace" => "libtmux/workspace"}.freeze

    def gem_index_problems(markdown, path, gems:, link:)
      header = "| Gem | Require | Use it for |"
      return ["#{path}: no #{header} index"] unless markdown.lines.any? { |line| line.chomp == header }

      gems.filter_map do |name|
        row = markdown.lines.find { |line| line.start_with?("| #{format(link, name, name)} |") }
        next "#{path}: the index has no row for #{name}" unless row

        "#{path}: the #{name} row does not give its require path" unless row.include?("| `#{REQUIRES.fetch(name)}` |")
      end
    end

    # Links belong in prose; a link inside a code fence is copied with the code.
    def fence_link_problems(markdown, path)
      fences(markdown).filter_map do |fence|
        next unless fence.lines.any? { |line| line.match?(%r{\[[^\]]+\]\(https?://}) }

        "#{path}:#{fence.line}: a #{fence.language} block contains a link"
      end
    end

    # A gems section heading links to the gem's directory on GitHub, and may
    # follow the link with a colon and the gem's job in plain words.
    def gem_heading_problems(markdown, path, gems:)
      gems.filter_map do |name|
        heading = /^#+ \[#{Regexp.escape(name)}\]\(#{Regexp.escape("#{GEM_TREE}/#{name}")}\)(?::\s\S.*)?\s*$/
        "#{path}: no heading links #{name} to #{GEM_TREE}/#{name}" unless markdown.match?(heading)
      end
    end
  end
end
