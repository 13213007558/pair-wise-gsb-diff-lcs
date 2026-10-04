# frozen_string_literal: true

class Diff::LCS::UnifiedPatch
  # A single physical line of text, kept separate from the line terminator that
  # follows it. `terminator` is `"\n"`, `"\r\n"`, or +nil+ when the line is the
  # last line of the input and has no line terminator (the "no newline at end
  # of file" case).
  #
  # An empty input is represented as an empty array. An input containing a
  # single empty line (e.g. `"\n"`) is represented as one line whose +text+ is
  # the empty string.
  Line = Data.define(:text, :terminator) do
    # The complete line as it appears in the source, including the terminator.
    def to_s
      text + terminator.to_s
    end
  end

  # Splits +text+ into Line objects without losing any information. Supported
  # terminators are `"\n"` and `"\r\n"`. A lone trailing `"\r"` is treated as
  # content, not a terminator.
  def self.split_lines(text)
    return text.dup if text.is_a?(Array)

    lines = []
    pos = 0

    while pos < text.bytesize
      nl = text.index("\n", pos) || text.bytesize
      content_end = nl

      terminator = nil

      if nl < text.bytesize
        terminator = "\n"

        if nl > pos && text.getbyte(nl - 1) == 13 # "\r".ord
          content_end = nl - 1
          terminator = "\r\n"
        end
      end

      lines << Line.new(text.byteslice(pos, content_end - pos), terminator)
      pos = (nl < text.bytesize) ? nl + 1 : text.bytesize
    end

    lines
  end

  # Joins Line objects back into a String, preserving terminators exactly.
  def self.join_lines(lines)
    lines.map(&:to_s).join
  end

  # Normalizes the +line_ending+ option to a concrete terminator.
  def self.terminator_for(line_ending, source_lines)
    case line_ending
    when :lf
      "\n"
    when :crlf
      "\r\n"
    when :preserve, nil
      source_lines.first&.terminator || "\n"
    else
      raise ArgumentError, "unknown line ending #{line_ending.inspect}"
    end
  end
end
