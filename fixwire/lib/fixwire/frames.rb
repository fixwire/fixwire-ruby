# frozen_string_literal: true

require "rbconfig"

module Fixwire
  # @api private reads exceptions and their stacks: frames from the oldest call to the newest, files
  # relative to the project, gems and Ruby's own library marked as not the app's.
  module Frames
    MAX_CHAIN = 10
    # Source lines come from regular files of at most MAX_SOURCE bytes, through a cache of at most
    # MAX_SOURCES files and MAX_CACHED bytes.
    MAX_SOURCE = 10 * 1024 * 1024
    MAX_SOURCES = 64
    MAX_CACHED = 32 * 1024 * 1024
    SOURCES_LOCK = Mutex.new
    SDK_DIR = File.expand_path("..", __dir__)
    # "block (2 levels) in Shop::Cart#checkout" (Ruby 3.4) or "block (2 levels) in checkout"
    LABEL = /\A(?<prefix>(?:(?:block(?: \(\d+ levels\))?|rescue|ensure) in )*)(?<owner>[A-Z][\w:]*)(?<sep>[#.])(?<name>[^#.\s]+)\z/
    # A backtrace line: "path:12:in 'label'" (3.4) or "path:12:in `label'"
    LINE = /\A(?<path>.+?):(?<line>\d+)(?::in [`'](?<label>.*)')?\z/

    class << self
      # The SDK's gems (integrations add theirs): their frames are not the app's.
      def sdk_dirs = (@sdk_dirs ||= [SDK_DIR])

      # The throwable and its causes, outermost first.
      def chain(exception, mechanism, handled, options)
        values = []
        seen = {}.compare_by_identity
        current = exception
        while current.is_a?(Exception) && !seen.key?(current) && values.size < MAX_CHAIN
          seen[current] = true
          values << ExceptionValue.new(
            type: current.class.name || current.class.to_s,
            message: safe_message(current),
            mechanism: values.empty? ? mechanism : "chained",
            handled: handled,
            frames: of(current, options)
          )
          current = current.cause
        end
        values
      end

      # The exception's frames, at most max_stack_frames, the newest kept (a stack overflow's
      # deepest calls); one captured without being raised gets the capturer's.
      def of(exception, options)
        if exception.backtrace_locations
          from_locations(exception.backtrace_locations, options)
        elsif exception.backtrace
          from_lines(exception.backtrace, options)
        else
          from_locations(caller_locations.reject { |l| sdk?(l.absolute_path.to_s) }, options)
        end
      end

      # Backtraces list the newest call first; frames go from the oldest.
      def from_locations(locations, options)
        frames = locations.first(options.max_stack_frames).map do |l|
          frame(l.absolute_path || l.path, l.lineno, l.label, options)
        end
        frames.reverse
      end

      def from_lines(lines, options)
        frames = lines.first(options.max_stack_frames).filter_map do |line|
          m = LINE.match(line.to_s)
          frame(m[:path], m[:line].to_i, m[:label], options) if m
        end
        frames.reverse
      end

      # One frame: its function and module from the label, its file as the app knows it.
      def frame(path, line, label, options)
        function = label
        mod = nil
        if label && (m = LABEL.match(label))
          mod = m[:owner]
          function = m[:prefix] + m[:name]
        end
        # Ruby before 3.4 names a rescue or ensure clause's frame on its own ("rescue in checkout");
        # 3.4 names the method: one name for both keeps an issue the same across Ruby versions.
        function = function&.gsub(/(?:rescue|ensure) in /, "")
        # A method written in C (Array#fetch) gets its caller's file and line: it isn't the app's.
        in_app = in_app?(mod, path, options) && !(m && m[:prefix].empty? && native?(m[:owner], m[:sep], m[:name]))
        frame = Frame.new(function: function, module: mod, file: display_path(path, options), line: line, in_app: in_app)
        context(frame, path, line, options.context_lines) if frame.in_app && line.to_i.positive?
        frame
      end

      # Whether Ruby 3.4's "Owner#name" (or "Owner.name") is a method without Ruby source.
      def native?(owner, sep, name)
        @native ||= {}
        key = "#{owner}#{sep}#{name}"
        return @native[key] if @native.key?(key)

        @native.shift if @native.size >= 1024
        klass = Object.const_get(owner)
        method = sep == "#" ? klass.instance_method(name) : klass.method(name)
        @native[key] = method.source_location.nil?
      rescue StandardError
        @native[key] = false
      end

      def in_app?(mod, path, options)
        if mod
          return false if options.in_app_exclude.any? { |p| mod.start_with?(p) }
          return true if options.in_app_include.any? { |p| mod.start_with?(p) }
        end
        return false if path.nil? || library?(path)

        path.start_with?("#{options.project_root}/")
      end

      # Gems (also bundled ones under vendor/), Ruby's library and the SDK itself.
      def library?(path)
        path.include?("/gems/") || path.include?("/vendor/bundle/") || sdk?(path) ||
          library_dirs.any? { |dir| path.start_with?(dir) } || path.start_with?("<internal:")
      end

      # The file as the app sees it: relative to the project; gems as name-version/path; Ruby's
      # library relative to it. No machine's home directory goes out.
      def display_path(path, options)
        return path if path.nil?
        return path.delete_prefix("#{options.project_root}/") if path.start_with?("#{options.project_root}/") && !library?(path)

        if (i = path.index("/gems/"))
          path[(i + 6)..]
        elsif (dir = sdk_dirs.find { |d| path.start_with?(d) })
          path.delete_prefix("#{File.dirname(dir, 2)}/") # fixwire-rails/lib/fixwire/rails.rb
        elsif (dir = library_dirs.find { |d| path.start_with?(d) })
          path.delete_prefix(dir).delete_prefix("/")
        else
          path
        end
      end

      def sdk?(path) = sdk_dirs.any? { |d| path.start_with?(d) }

      def library_dirs
        @library_dirs ||= [RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["rubyarchdir"]].compact.map { |d| d.chomp("/") }
      end

      def context(frame, path, line, around)
        return if around <= 0

        lines = source(path)
        return if lines.nil? || line > lines.size

        frame.context_line = lines[line - 1]
        frame.pre_context = lines[[line - 1 - around, 0].max...(line - 1)]
        frame.post_context = lines[line, around] || []
      end

      def source(path)
        SOURCES_LOCK.synchronize do
          @sources ||= {}
          return @sources[path] if @sources.key?(path)

          lines = (File.readlines(path, chomp: true) if File.file?(path) && File.size(path) <= MAX_SOURCE)
          @cached = @cached.to_i + bytes(lines)
          @cached -= bytes(@sources.shift[1]) while @sources.any? && (@sources.size >= MAX_SOURCES || @cached > MAX_CACHED)
          @sources[path] = lines
        end
      rescue StandardError
        nil
      end

      def bytes(lines) = lines.nil? ? 0 : lines.sum(&:bytesize)

      def safe_message(exception)
        exception.message.to_s
      rescue StandardError
        exception.class.to_s
      end
    end
  end
end
