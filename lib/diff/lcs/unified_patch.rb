# frozen_string_literal: true

require "diff/lcs" unless defined?(Diff)
require_relative "unified_patch/lines"
require_relative "unified_patch/plan"
require_relative "unified_patch/parser"
require_relative "unified_patch/engine"
require_relative "unified_patch/applier"

class Diff::LCS::UnifiedPatch
  # Locates the hunks of a unified diff against +original+ using surrounding
  # context and returns a complete atomic application Plan without modifying
  # anything.
  #
  # The patch is treated strictly as data: `---`, `+++`, and other headers are
  # parsed for information but their paths are never opened.
  #
  # ## Options
  #
  # - +max_offset:+ maximum absolute line distance permitted between a hunk's
  #   declared position and its located position. +nil+ (the default) allows
  #   any distance.
  # - +fuzz:+ number of leading and trailing context lines that may be ignored
  #   while locating each hunk (0 by default, like `patch -F`).
  # - +line_ending:+ terminator used for newly inserted lines when no
  #   surrounding line determines one. One of +:preserve+ (default), +:lf+,
  #   +:crlf+.
  #
  # All hunks are located jointly. A plan is only produced when there is a
  # single cheapest compatible placement; ties return an +:ambiguous+ plan and
  # failures return +:failed+, and in both cases +new_text+ is +nil+ so the
  # original text is left unchanged.
  def self.apply(original, patch_text, max_offset: nil, fuzz: 0, line_ending: :preserve)
    klass = Diff::LCS::UnifiedPatch
    options = klass::Options.build(max_offset: max_offset, fuzz: fuzz, line_ending: line_ending)

    original_text =
      if original.is_a?(Array)
        original.map(&:to_s).join("\n")
      else
        original.to_s
      end

    source_lines = klass.split_lines(original_text)
    parsed = klass.parse(patch_text)

    malformed_failures = parsed.malformed.map do |_header_index, reason, detail|
      klass::FailedHunk.new(nil, reason, detail, [])
    end

    return build_failed(original_text, malformed_failures, options) if malformed_failures.any?

    if parsed.hunks.empty?
      return build_failed(
        original_text,
        [klass::FailedHunk.new(nil, :no_hunks, "the patch contains no unified-diff hunks", [])],
        options
      )
    end

    candidate_sets, locate_failures = klass.enumerate(parsed.hunks, source_lines, options)
    status, plans, search_failure = klass.solve(candidate_sets, parsed.hunks)

    case status
    when :unique
      result = klass.apply_result(source_lines, plans.first, options)

      klass::Plan.new(
        :applied, original_text, result.new_text, plans.first, [],
        [], result.mapping, options
      )
    when :ambiguous
      klass::Plan.new(:ambiguous, original_text, nil, [], [], plans, [], options)
    else
      failures = locate_failures.dup
      failures << search_failure if search_failure

      if failures.empty?
        failures << klass::FailedHunk.new(
          nil, :incompatible,
          "individual hunks match, but no combination keeps them ordered and " \
            "without selecting the same source lines",
          candidate_sets
        )
      end

      build_failed(original_text, failures, options)
    end
  end

  def self.build_failed(original_text, failures, options)
    Diff::LCS::UnifiedPatch::Plan.new(
      :failed, original_text, nil, [], failures, [], [], options
    )
  end
  private_class_method :build_failed

end

module Diff::LCS
  # Convenience wrapper for Diff::LCS::UnifiedPatch.apply; see that method for
  # options and the structure of the returned plan.
  def self.apply_unified_patch(original, patch_text, max_offset: nil, fuzz: 0, line_ending: :preserve)
    Diff::LCS::UnifiedPatch.apply(
      original, patch_text,
      max_offset: max_offset, fuzz: fuzz, line_ending: line_ending
    )
  end
end
