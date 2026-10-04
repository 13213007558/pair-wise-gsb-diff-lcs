# frozen_string_literal: true

class Diff::LCS::UnifiedPatch
  # Result of parsing and locating a single hunk header `@@ -a,n +b,n @@`.
  #
  # +tokens+ is an Array of `[kind, text]` pairs where +kind+ is one of:
  #
  # - `:context` (a leading space in the hunk body),
  # - `:remove` (a leading `-`),
  # - `:insert` (a leading `+`).
  #
  # +text+ is the remainder of the body line with its prefix removed and
  # without any trailing line terminator. The +old_missing_newline+ and
  # +new_missing_newline+ flags record `\\ No newline at end of file` markers
  # following the last old-side / new-side line of the hunk.
  Hunk = Data.define(
    :header_index,
    :old_start, :old_count, :new_start, :new_count,
    :tokens, :old_missing_newline, :new_missing_newline
  )

  # A candidate location considered for a hunk while solving the plan.
  Candidate = Data.define(
    :hunk_index, :anchor_start, :anchor_end, :fuzz, :offset,
    :dropped_leading, :dropped_trailing
  )

  # The chosen placement of a hunk within the complete application plan.
  #
  # +old_start+ / +old_end+ are zero-based, half-open indexes into the original
  # source lines covered by the located anchor. +declared_start+ is the
  # zero-based position implied by the hunk header, so +offset = old_start -
  # declared_start+. +fuzz+ is the number of context lines dropped from each
  # side while locating the hunk.
  HunkPlan = Data.define(
    :hunk_index, :old_start, :old_end, :declared_start,
    :offset, :fuzz, :tokens, :old_missing_newline, :new_missing_newline,
    :dropped_leading, :dropped_trailing
  ) do
    def applied? = true
  end

  # Explains why a particular hunk could not be placed in the unique plan.
  #
  # +reason+ is a stable Symbol (`:no_match`, `:offset_exceeded`,
  # `:incompatible`, `:malformed_hunk`, ...). +detail+ is a human-readable
  # String and +candidates+ (when present) lists the locations that were
  # considered but rejected.
  FailedHunk = Data.define(:hunk_index, :reason, :detail, :candidates) do
    def applied? = false
  end

  # Mapping information for one original source line.
  #
  # +old_index+ is the zero-based source line number. +new_index+ is the
  # zero-based position of that same line in the produced text, or +nil+ when
  # the line was removed. +start_column+ / +end_column+ describe the line's
  # content (excluding its terminator) within the produced String.
  LineMapEntry = Data.define(:old_index, :new_index, :start_column, :end_column)

  # The complete, atomic application plan returned by
  # Diff::LCS.apply_unified_patch.
  #
  # +status+ is one of:
  #
  # - `:applied` — exactly one compatible plan exists; +new_text+ contains the
  #   result and +mapping+ contains the coordinate mapping.
  # - `:ambiguous` — multiple equally-good plans exist; +new_text+ is +nil+
  #   and the original text must be left unchanged. +alternatives+ contains
  #   the tied placements.
  # - `:failed` — no plan exists; +new_text+ is +nil+ and +failures+ explains
  #   every rejected option.
  #
  # +original_text+ is always returned unchanged so callers can verify that
  # nothing was mutated when the plan is not unique.
  Plan = Data.define(
    :status, :original_text, :new_text, :hunks, :failures,
    :alternatives, :mapping, :options
  ) do
    def applied? = status == :applied
    def ambiguous? = status == :ambiguous
    def failed? = status == :failed

    def new_lines
      return [] if new_text.nil?

      Diff::LCS::UnifiedPatch.split_lines(new_text)
    end
  end
end
