# frozen_string_literal: true

class Diff::LCS::UnifiedPatch
  MISSING_NEWLINE_MARKER = "\\ No newline at end of file"

  HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:[ \t].*)?\z/

  ParsedPatch = Data.define(:hunks, :headers, :malformed) do
    def valid? = malformed.empty?
  end

  # Parses unified-diff +patch+ data into Hunk objects. The patch is treated
  # strictly as data: `---` / `+++` headers and paths are recorded but never
  # opened or otherwise acted upon.
  #
  # Returns a ParsedPatch. Parse problems are reported in +malformed+ as
  # `[header_index, reason, detail]` triples instead of being raised.
  def self.parse(patch)
    raw_lines = split_raw(patch)

    hunks = []
    headers = []
    malformed = []

    current = nil # :nodoc: currently-open hunk state
    previous_kind = nil

    finish = lambda do
      next if current.nil?

      hunk = current[:hunk]
      old_seen = hunk.tokens.count { |kind,| kind != :insert }
      new_seen = hunk.tokens.count { |kind,| kind != :remove }

      if old_seen != hunk.old_count || new_seen != hunk.new_count
        malformed << [
          hunk.header_index,
          :malformed_hunk,
          "hunk header declares #{hunk.old_count}/#{hunk.new_count} " \
            "old/new lines, but the body contains #{old_seen}/#{new_seen}"
        ]
      else
        hunks << hunk
      end

      current = nil
      previous_kind = nil
    end

    raw_lines.each_with_index do |raw, line_index|
      body = raw[:text]

      if (match = HUNK_HEADER.match(body))
        finish.call

        old_start = match[1].to_i
        old_count = match[2].nil? ? 1 : match[2].to_i
        new_start = match[3].to_i
        new_count = match[4].nil? ? 1 : match[4].to_i

        current = {
          hunk: Hunk.new(
            line_index, old_start, old_count, new_start, new_count,
            [], false, false
          )
        }
      elsif current
        marker = body.end_with?("\r") ? body.chop : body

        if marker == MISSING_NEWLINE_MARKER
          case previous_kind
          when :context
            current[:hunk] = current[:hunk].with(
              old_missing_newline: true, new_missing_newline: true
            )
          when :remove
            current[:hunk] = current[:hunk].with(old_missing_newline: true)
          when :insert
            current[:hunk] = current[:hunk].with(new_missing_newline: true)
          else
            malformed << [line_index, :malformed_hunk,
              "missing-newline marker is not attached to a hunk body line"]
          end
        elsif body.empty?
          # A bare empty line inside a hunk body is treated as an empty
          # context line (the leading space is commonly stripped by tools).
          current[:hunk].tokens << [:context, ""]
          previous_kind = :context
        else
          prefix = body[0]
          content = body[1..] || ""

          kind =
            case prefix
            when " " then :context
            when "-" then :remove
            when "+" then :insert
            end

          if kind.nil?
            # Anything unrecognised while a hunk is open ends the hunk. A bare
            # '\' line that is not the canonical marker is malformed.
            if prefix == "\\"
              malformed << [line_index, :malformed_hunk,
                "unrecognised escaped hunk line: #{body.inspect}"]
            end

            finish.call
          else
            crlf = content&.end_with?("\r")
            content = content.chop if crlf

            current[:hunk].tokens << [kind, content, crlf ? :crlf : nil].compact
            previous_kind = kind
          end
        end
      elsif body.start_with?("--- ", "+++ ", "diff ", "index ", "new file mode",
        "deleted file mode", "old mode", "new mode", "similarity index",
        "dissimilarity index", "copy from", "copy to", "rename from", "rename to",
        "GIT binary patch", "Binary files")
        headers << [line_index, body]
      elsif body.start_with?("\\")
        malformed << [line_index, :malformed_hunk,
          "missing-newline marker appears outside of a hunk"]
      end
    end

    finish.call

    ParsedPatch.new(hunks.freeze, headers.freeze, malformed.freeze)
  end

  # Splits patch data into raw physical lines as `{text:, newline:}` pairs,
  # removing exactly one trailing `"\n"` per line (so a trailing `"\r"`
  # remains visible to the hunk parser as CRLF content).
  def self.split_raw(patch)
    text = patch.is_a?(Array) ? patch.map(&:to_s).join("\n") : patch.to_s

    lines = []
    pos = 0

    while pos <= text.bytesize
      nl = text.index("\n", pos)

      if nl.nil?
        lines << {text: text.byteslice(pos..), newline: false} unless pos == text.bytesize
        break
      else
        lines << {text: text.byteslice(pos...nl), newline: true}
        pos = nl + 1
      end
    end

    lines
  end
end
