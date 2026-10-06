# frozen_string_literal: true

module Fixwire
  module Internal
    module Redaction
      # One walk of a JSON-like value with the server's rules: a typed attribute
      # ({"type" => ..., "value" => ...}) keeps its shape, a list of two holding
      # a sensitive key and a value is a pair, and keys hold data too (keys
      # that mask alike are numbered in code-point order: "[REDACTED:email] (2)").
      #
      # Hashes and arrays are rebuilt, never changed. Symbols count as the
      # strings they name, as JSON writes them; other values (numbers, true,
      # false, nil, other objects) stay as they are, and so do containers
      # nested deeper than MAX_DEPTH (the server masks those).
      class Walker
        MAX_DEPTH = 512
        # A numbered key: "[REDACTED:email] (2)".
        NUMBERED = /\A(.*) \(([0-9]+)\)\z/m

        attr_reader :count

        def initialize(redactor)
          @redactor = redactor
          @count = 0
        end

        def value(value, depth = 0)
          case value
          when String then walk_string(value)
          when Symbol then walk_symbol(value)
          when Hash then depth < MAX_DEPTH ? walk_hash(value, depth) : value
          when Array then depth < MAX_DEPTH ? walk_array(value, depth) : value
          else value
          end
        end

        private

        def walk_string(value)
          masked, findings = @redactor.mask(value)
          @count += findings.size
          masked
        end

        def walk_symbol(value)
          name = value.name
          masked, findings = @redactor.mask(name)
          return value if findings.empty? && masked == name

          @count += findings.size
          masked
        end

        # Some maps are sent as [key, value] pairs (headers, tags).
        def walk_array(list, depth)
          key = text(list[0]) if list.size == 2
          if key && !blank?(list[1]) && @redactor.sensitive?(key)
            @count += 1
            return [list[0], FILTERED]
          end
          list.map { |item| value(item, depth + 1) }
        end

        def walk_hash(map, depth)
          out = {}
          names = []
          renamed = []
          map.each do |key, val|
            name = key_text(key)
            out_key = key.is_a?(String) ? name : key
            masked, findings = @redactor.mask(name)
            renamed << [name, out_key, masked, findings.size] unless findings.empty?
            names << name
            out[out_key] = !blank?(val) && @redactor.sensitive?(name) ? filter(val) : value(val, depth + 1)
          end
          renamed.empty? ? out : rename(out, names, renamed)
        end

        # The value of a sensitive key, filtered whole.
        def filter(val)
          slot = val.is_a?(Hash) && value_key(val)
          return filter_typed(val, slot) if slot && !val[slot].nil?
          return val if text(val) == FILTERED

          @count += 1
          FILTERED
        end

        # A typed attribute keeps its shape; nothing else in it is walked.
        def filter_typed(attribute, slot)
          return attribute if text(attribute[slot]) == FILTERED

          @count += 1
          attribute.merge(slot => FILTERED, type_key(attribute, slot) => "string")
        end

        def value_key(map)
          if map.key?("value")
            "value"
          elsif map.key?(:value)
            :value
          end
        end

        # The attribute's "type" key, else one like its "value" key.
        def type_key(attribute, slot)
          return "type" if attribute.key?("type")
          return :type if attribute.key?(:type) || slot.is_a?(Symbol)

          "type"
        end

        # Keys that mask alike are numbered in code-point order (the byte order
        # of UTF-8), each taking the first name no key holds at its turn. The
        # number to try first is kept per masked name, so that thousands of
        # keys masking alike (request headers) don't each count up from 2; a
        # name no key holds any more lowers it again.
        def rename(out, names, renamed)
          taken = names.to_h { |name| [name, true] }
          first = {}
          new_keys = {}
          renamed.each_with_index.sort_by { |(name, *), i| [name, i] }.each do |(name, out_key, masked, findings), _|
            n = first.fetch(masked, 1)
            key = n == 1 ? masked : "#{masked} (#{n})"
            while taken.key?(key)
              n += 1
              key = "#{masked} (#{n})"
            end
            first[masked] = n + 1
            taken.delete(name)
            freed(first, name)
            taken[key] = true
            new_keys[out_key] = key
            @count += findings
          end
          out.to_h { |k, v| [new_keys.fetch(k, k), v] }
        end

        # A name set free may be what its masked name, or the one it numbers,
        # should try first.
        def freed(first, name)
          first[name] = 1 if first.key?(name)
          base, n = NUMBERED.match(name)&.captures
          first[base] = [first[base], n.to_i].min if base && n.to_i >= 2 && first.key?(base)
        end

        def key_text(key)
          case key
          when String then Text.utf8(key)
          when Symbol then Text.utf8(key.name)
          else Text.utf8(key.to_s)
          end
        end

        def text(value)
          case value
          when String then value
          when Symbol then value.name
          end
        end

        def blank?(value)
          value.nil? || ((value.is_a?(String) || value.is_a?(Symbol)) && value.empty?)
        end
      end
    end
  end
end
