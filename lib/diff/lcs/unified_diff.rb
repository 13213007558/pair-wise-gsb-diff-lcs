# frozen_string_literal: true

require "diff/lcs"

# Applies unified diff text to an in-memory source string. Paths in the diff are
# treated as patch data only; they are never opened or otherwise acted upon.
class Diff::LCS::UnifiedDiff
  Hunk = Data.define(:old_start, :old_count, :new_start, :new_count, :lines, :header_line)
  Line = Data.define(:op, :text, :no_newline)
  Location = Data.define(
    :hunk_index, :expected_start_line, :actual_start_line, :offset,
    :source_range, :ignored_leading_context, :ignored_trailing_context
  )
  Coordinate = Data.define(:output_line, :source_line)
  OutputLine = Data.define(:text, :source_line)
  Reason = Data.define(:code, :message)
  Plan = Data.define(:status, :new_text, :coordinate_mapping, :source_line_map, :hunks, :alternatives, :reasons) do
    def applied? = status == "applied"

    def ambiguous? = status == "ambiguous"

  end

  HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
  private_constant :HEADER

  MISSING_NEWLINE = "\\ No newline at end of file"
  private_constant :MISSING_NEWLINE

  Candidate = Data.define(
    :hunk_index, :full_start, :full_end, :selected_start, :selected_end,
    :delete_start, :delete_end, :body_start, :body_end,
    :left_trim, :right_trim, :score
  )
  private_constant :Candidate

  class ParseError < StandardError; end

  def self.apply(source, patch, max_offset: nil, ignored_context_lines: 0)
    new(source, patch, max_offset, ignored_context_lines).call
  end

  def initialize(source, patch, max_offset, ignored_context_lines)
    unless source.is_a?(String) && patch.is_a?(String)
      fail ArgumentError, "source and patch must be Strings"
    end

    unless max_offset.nil? || (max_offset.is_a?(Integer) && max_offset >= 0)
      fail ArgumentError, "max_offset must be a non-negative Integer or nil"
    end

    unless ignored_context_lines.is_a?(Integer) && ignored_context_lines >= 0
      fail ArgumentError, "ignored_context_lines must be a non-negative Integer"
    end

    @source = source
    @patch = patch
    @max_offset = max_offset
    @ignored_context_lines = ignored_context_lines
    @source_lines = source.lines
  end

  def call
    hunks, target_files = parse

    if target_files > 1
      return failure("multiple_targets", "unified diff contains more than one target file; paths are not applied")
    end

    return identity_plan("applied", [], []) if hunks.empty?

    candidates = hunks.each_with_index.map { |hunk, index| candidates_for(hunk, index) }

    unless candidates.each_with_index.all? { |list, index| valid_candidates?(list, index) }
      reasons = candidates.each_with_index.filter_map do |list, index|
        next unless list.empty?

        Reason.new("hunk_not_found", "hunk #{index + 1} has no location within the permitted offset and context fuzz")
      end

      return identity_plan("unmatched", [], reasons)
    end

    paths = best_paths(candidates)

    if paths.empty?
      reason = Reason.new("incompatible_hunks", "the hunks do not have a mutually compatible set of locations")
      return identity_plan("incompatible", [], [reason])
    end

    if paths.length > 1
      message = "more than one complete application plan has the same context score"
      reason = Reason.new("ambiguous_hunk_locations", message)
      alternatives = paths.map { |path| path.map { |candidate| location_for(candidate, hunks[candidate.hunk_index]) } }
      return identity_plan("ambiguous", alternatives, [reason])
    end

    selected = paths.first
    new_lines = apply_path(selected, hunks)
    mapping = coordinate_mapping(new_lines)
    locations = selected.map { |candidate| location_for(candidate, hunks[candidate.hunk_index]) }

    Plan.new(
      "applied",
      new_lines.map(&:text).join,
      mapping,
      mapping.map(&:source_line),
      locations,
      [],
      []
    )
  rescue ParseError => error
    identity_plan("invalid", [], [Reason.new("invalid_unified_diff", error.message)])
  end

  private

  def parse
    lines = @patch.lines
    hunks = []
    target_files = 0
    index = 0

    while index < lines.length
      raw = lines[index]

      if raw.start_with?("+++ ")
        target_files += 1
        index += 1
        next
      end

      match = HEADER.match(raw)

      if match
        hunk, index = parse_hunk(lines, index, match)
        hunks << hunk
        next
      end

      index += 1
    end

    [hunks, target_files]
  end

  def parse_hunk(lines, index, match)
    header_line = index + 1
    old_start = match[1].to_i
    old_count = match[2] ? match[2].to_i : 1
    new_start = match[3].to_i
    new_count = match[4] ? match[4].to_i : 1

    old_start -= 1 unless old_count.zero?
    new_start -= 1 unless new_count.zero?

    body = []
    seen_old = 0
    seen_new = 0
    index += 1

    loop do
      counts_complete = seen_old == old_count && seen_new == new_count
      break if counts_complete && !missing_newline_marker?(lines[index])

      if index >= lines.length
        fail ParseError, "unexpected end of patch in hunk starting on line #{header_line}"
      end

      raw = lines[index]

      if missing_newline_marker?(raw)
        fail ParseError, "missing-newline marker on line #{index + 1} does not follow a diff line" if body.empty?
        fail ParseError, "duplicate missing-newline marker on line #{index + 1}" if body.last.no_newline

        body[-1] = body.last.with(no_newline: true, text: body.last.text.chomp("\r\n").chomp("\n"))
        index += 1
        next
      end

      op = raw[0]

      unless %w[space - +].include?(op == " " ? "space" : op)
        fail ParseError, "invalid unified diff body line #{index + 1}: #{raw.inspect}"
      end

      content, terminator = diff_content(raw)
      no_newline = terminator.empty?
      text = no_newline ? content : content + terminator
      line = Line.new(op == "space" ? " " : op, text, no_newline)

      seen_old += 1 if line.op == " " || line.op == "-"
      seen_new += 1 if line.op == " " || line.op == "+"

      if seen_old > old_count || seen_new > new_count
        fail ParseError, "hunk starting on line #{header_line} contains more body lines than its header declares"
      end

      body << line
      index += 1
    end

    if seen_old != old_count || seen_new != new_count
      fail ParseError, "hunk starting on line #{header_line} contains fewer body lines than its header declares"
    end

    [Hunk.new(old_start, old_count, new_start, new_count, body, header_line), index]
  end

  def missing_newline_marker?(raw)
    raw && raw.chomp("\r\n").chomp("\n") == MISSING_NEWLINE
  end

  def diff_content(raw)
    payload = raw[1..].to_s

    terminator =
      if payload.end_with?("\r\n")
        "\r\n"
      elsif payload.end_with?("\n")
        "\n"
      else
        ""
      end

    [payload.chomp(terminator), terminator]
  end

  def candidates_for(hunk, hunk_index)
    old_positions = hunk.lines.each_index.select do |body_index|
      hunk.lines[body_index].op == " " || hunk.lines[body_index].op == "-"
    end

    leading_context = hunk.lines.take_while { |line| line.op == " " }.length
    trailing_context = hunk.lines.reverse_each.take_while { |line| line.op == " " }.length

    candidates = []

    (0..[@ignored_context_lines, leading_context].min).each do |left_trim|
      remaining = @ignored_context_lines - left_trim
      max_trailing = [remaining, trailing_context].min

      (0..max_trailing).each do |right_trim|
        candidates.concat(candidates_with_trim(hunk, hunk_index, old_positions, left_trim, right_trim))
      end
    end

    candidates
      .group_by { |candidate| [candidate.full_start, candidate.full_end] }
      .values
      .map { |group| group.max_by { |candidate| [candidate.score, -candidate.left_trim, -candidate.right_trim] } }
      .sort_by { |candidate| [candidate.full_start, candidate.full_end, candidate.hunk_index] }
  end

  def candidates_with_trim(hunk, hunk_index, old_positions, left_trim, right_trim)
    body_start = left_trim
    body_end = hunk.lines.length - right_trim
    selected_positions = old_positions.select { |position| position >= body_start && position < body_end }

    if selected_positions.empty?
      insertion_candidates(hunk, hunk_index, body_start, body_end, left_trim, right_trim)
    else
      matching_candidates(
        hunk, hunk_index, selected_positions,
        body_start, body_end, left_trim, right_trim
      )
    end
  end

  def insertion_candidates(hunk, hunk_index, body_start, body_end, left_trim, right_trim)
    leading_context = hunk.lines.take_while { |line| line.op == " " }.length
    anchor = hunk.old_count.zero? ? hunk.old_start : hunk.old_start + leading_context

    return [] unless anchor >= 0 && anchor <= @source_lines.length
    return [] unless within_offset?(anchor, hunk.old_start)

    [
      Candidate.new(
        hunk_index, hunk.old_start, hunk.old_start + hunk.old_count,
        anchor, anchor, anchor, anchor, body_start, body_end,
        left_trim, right_trim, 0
      )
    ]
  end

  def matching_candidates(hunk, hunk_index, selected_positions, body_start, body_end, left_trim, right_trim)
    first_position = selected_positions.first
    prior_old_count = hunk.lines.first(first_position).count { |line| line.op == " " || line.op == "-" }
    pattern = selected_positions.map { |position| hunk.lines[position].text }

    (0..@source_lines.length - pattern.length).filter_map do |selected_start|
      next unless @source_lines[selected_start, pattern.length] == pattern

      full_start = selected_start - prior_old_count
      full_end = full_start + hunk.old_count
      selected_end = selected_start + pattern.length
      old_change_positions = hunk.lines.each_index.filter_map do |body_index|
        if hunk.lines[body_index].op == "-"
          preceding_old_lines = hunk.lines.first(body_index).count do |line|
            line.op == " " || line.op == "-"
          end

          full_start + preceding_old_lines
        end
      end
      change_start = old_change_positions.first || selected_end
      change_end = old_change_positions.last ? old_change_positions.last + 1 : selected_end

      next if full_start < 0 || full_end > @source_lines.length
      next unless within_offset?(full_start, hunk.old_start)

      Candidate.new(
        hunk_index, full_start, full_end, selected_start, selected_end,
        change_start, change_end, body_start, body_end,
        left_trim, right_trim, pattern.length
      )
    end
  end

  def within_offset?(actual, expected)
    @max_offset.nil? || (actual - expected).abs <= @max_offset
  end

  def valid_candidates?(candidates, _hunk_index)
    !candidates.empty?
  end

  def best_paths(candidates_by_hunk)
    find_paths = lambda do |hunk_index, minimum_start|
      if hunk_index == candidates_by_hunk.length
        next [[0, []]]
      end

      choices = candidates_by_hunk[hunk_index].select { |candidate| candidate.delete_start >= minimum_start }
      best = []

      choices.each do |candidate|
        find_paths.call(hunk_index + 1, candidate.delete_end).each do |tail|
          best << [candidate.score + tail[0], [candidate, *tail[1]]]
        end
      end

      highest = best.map(&:first).max
      return [] if highest.nil?

      best
        .select { |choice| choice[0] == highest }
        .uniq do |choice|
          choice[1].map do |candidate|
            [candidate.delete_start, candidate.delete_end]
          end
        end
        .first(2)
    end

    find_paths.call(0, 0).map(&:last)
  end

  def apply_path(path, hunks)
    result = []
    removed = {}
    insertions = Hash.new { |hash, key| hash[key] = [] }

    path.each do |candidate|
      hunk = hunks[candidate.hunk_index]

      hunk.lines.each_index do |body_index|
        line = hunk.lines[body_index]
        next unless line.op == "-" || line.op == "+"

        preceding_old_lines = hunk.lines.first(body_index).count { |item| item.op == " " || item.op == "-" }
        source_index = candidate.full_start + preceding_old_lines

        case line.op
        when "-"
          removed[source_index] = true
        when "+"
          insertions[source_index] << OutputLine.new(line.text, nil)
        end
      end
    end

    @source_lines.each_with_index do |line, index|
      result.concat(insertions[index])
      result << OutputLine.new(line, index + 1) unless removed.key?(index)
    end

    result.concat(insertions[@source_lines.length])
    result
  end

  def coordinate_mapping(lines)
    lines.each_with_index.map do |line, index|
      Coordinate.new(index + 1, line.source_line)
    end
  end

  def location_for(candidate, hunk)
    Location.new(
      candidate.hunk_index + 1,
      hunk.old_start + 1,
      candidate.full_start + 1,
      candidate.full_start - hunk.old_start,
      [candidate.full_start + 1, candidate.full_end + 1],
      candidate.left_trim,
      candidate.right_trim
    )
  end

  def identity_plan(status, alternatives, reasons)
    mapping = @source_lines.each_with_index.map { |_line, index| Coordinate.new(index + 1, index + 1) }
    Plan.new(status, @source, mapping, mapping.map(&:source_line), [], alternatives, reasons)
  end

  def failure(code, message)
    identity_plan("invalid", [], [Reason.new(code, message)])
  end
end
