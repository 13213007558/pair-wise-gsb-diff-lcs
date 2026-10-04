# frozen_string_literal: true

class Diff::LCS::UnifiedPatch
  # Builds the resulting text and the original-to-new coordinate mapping for a
  # concrete, already-validated set of HunkPlan placements.
  AppliedResult = Data.define(:new_text, :mapping)

  def self.apply_result(original_lines, hunk_plans, options)
    plans = hunk_plans.sort_by(&:old_start)
    output = []
    mapping = Array.new(original_lines.size)
    cursor = 0
    columns = 0
    default_terminator = terminator_for(options.line_ending, original_lines)

    emit = lambda do |line, old_index|
      start_column = columns
      output << line
      columns += line.to_s.bytesize

      if old_index
        mapping[old_index] = LineMapEntry.new(
          old_index, output.size - 1, start_column, start_column + line.text.bytesize
        )
      end
    end

    plans.each do |plan|
      while cursor < plan.old_start
        emit.call(original_lines[cursor], cursor)
        cursor += 1
      end

      source_index = plan.old_start
      skipped_leading = 0

      last_new_token_index = plan.tokens.rindex { |kind,| kind != :remove }
      last_hunk = plans.last.equal?(plan)

      plan.tokens.each_with_index do |(kind, text), token_index|
        if kind == :context && skipped_leading < plan.dropped_leading
          skipped_leading += 1
          source_index += 1
          next
        end

        case kind
        when :context
          if source_index < plan.old_end
            line = original_lines.fetch(source_index)
            emit.call(Line.new(line.text, line.terminator), source_index)
            source_index += 1
          end
        when :remove
          mapping[source_index] = nil
          source_index += 1
        when :insert
          terminator = insert_terminator(
            plan, token_index == last_new_token_index,
            last_hunk, original_lines, default_terminator
          )
          emit.call(Line.new(text, terminator), nil)
        end
      end

      # Tokens cover the entire declared old span. The anchor is a sub-range of
      # that span; everything after the anchor is trailing fuzz context that
      # remains unchanged and is handled by the normal cursor loop.
      cursor = plan.old_end
    end

    while cursor < original_lines.size
      emit.call(original_lines[cursor], cursor)
      cursor += 1
    end

    AppliedResult.new(join_lines(output), mapping)
  end

  # Terminators for inserted lines follow surrounding source lines. Only the
  # final line of the new file may legitimately lack a terminator, and that is
  # recorded by the hunk's new-side missing-newline marker.
  def self.insert_terminator(plan, is_last_new_token, last_hunk, original_lines, default)
    at_eof = plan.old_end == original_lines.size

    if is_last_new_token && plan.new_missing_newline && last_hunk && at_eof
      nil
    else
      surrounding_index = plan.old_end == plan.old_start ? plan.old_start : plan.old_end - 1
      original_lines[surrounding_index]&.terminator || default
    end
  end
  private_class_method :insert_terminator
end
