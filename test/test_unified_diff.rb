# frozen_string_literal: true

require_relative "test_helper"

class TestUnifiedDiff < Minitest::Test
  def plan(...) = Diff::LCS.apply_unified_diff(...)

  def test_ambiguous_repeated_context_returns_complete_plans_without_changes
    source = "A\nM\nX\nB\nM\nY\nC\n"
    patch = "@@ -2 +2 @@\n-M\n+F\n"

    result = plan(source, patch)

    assert_predicate result, :ambiguous?
    assert_equal source, result.new_text
    assert_empty result.hunks
    assert_equal ["ambiguous_hunk_locations"], result.reasons.map(&:code)
    assert_equal [[[2, 3]], [[5, 6]]], result.alternatives.map { |path| path.map(&:source_range) }
  end

  def test_another_hunk_selects_the_unique_compatible_plan
    source = "A\nM\nX\nB\nM\nY\nC\n"
    patch = "@@ -2 +2 @@\n-M\n+F\n@@ -3 +3 @@\n-X\n+Z\n"

    result = plan(source, patch)

    assert_predicate result, :applied?
    assert_equal "A\nF\nZ\nB\nM\nY\nC\n", result.new_text
    assert_equal [1, nil, nil, 4, 5, 6, 7], result.source_line_map
    assert_equal [[2, 3], [3, 4]], result.hunks.map(&:source_range)
    assert_empty result.reasons
  end

  def test_adjacent_hunks_may_overlap_in_unchanged_context
    source = "a\nshared\nb\nshared\nc\n"
    patch =
      "@@ -1,4 +1,4 @@\n a\n shared\n-b\n+B\n shared\n" \
      "@@ -2,4 +2,4 @@\n shared\n b\n shared\n-c\n+D\n"

    result = plan(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\nshared\nB\nshared\nD\n", result.new_text
  end

  def test_hunks_are_located_within_the_configured_maximum_offset
    source = "introduction\nadded note\ncontext\nold\ntail\n"
    patch = "@@ -2,2 +2,2 @@\n context\n-old\n+new\n tail\n"

    shifted = plan(source, patch)
    exact = plan(source, patch, max_offset: 0)

    assert_predicate shifted, :applied?
    assert_equal "introduction\nadded note\ncontext\nnew\ntail\n", shifted.new_text
    assert_equal 1, shifted.hunks.first.offset
    assert_equal "unmatched", exact.status
    assert_equal source, exact.new_text
  end

  def test_context_fuzz_ignores_only_the_configured_total_edge_lines
    source = "actual\nold\nending\n"
    patch = "@@ -1,3 +1,3 @@\n missing-leading\n-old\n+new\n missing-trailing\n"

    one_side = plan(source, patch, ignored_context_lines: 1)
    both_sides = plan(source, patch, ignored_context_lines: 2)

    assert_equal "unmatched", one_side.status
    assert_predicate both_sides, :applied?
    assert_equal "actual\nnew\nending\n", both_sides.new_text
  end

  def test_crlf_line_endings_are_preserved
    source = "keep\r\nold\r\n"
    patch = "@@ -1,2 +1,2 @@\n keep\r\n-old\r\n+new\r\n"

    result = plan(source, patch)

    assert_predicate result, :applied?
    assert_equal "keep\r\nnew\r\n", result.new_text
  end

  def test_missing_newline_at_end_of_file_is_preserved
    source = "a\nold"
    patch =
      "@@ -1,2 +1,2 @@\n a\n-old\n" \
      "\\ No newline at end of file\n+new\n\\ No newline at end of file\n"

    result = plan(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\nnew", result.new_text
    refute result.new_text.end_with?("\n")
  end

  def test_physical_blank_context_line_is_distinct_from_a_malformed_prefix
    source = "a\n\nb\n"
    valid_patch = "@@ -1,3 +1,3 @@\n a\n \n b\n"
    malformed_patch = "@@ -1 +1 @@\na\n"

    assert_predicate plan(source, valid_patch), :applied?
    assert_equal [1, 2, 3], plan(source, valid_patch).source_line_map

    result = plan("a\n", malformed_patch)

    assert_equal "invalid", result.status
    assert_equal "invalid_unified_diff", result.reasons.first.code
  end

  def test_paths_in_the_patch_are_not_opened_or_used_for_selection
    source = "old\n"
    patch = <<~PATCH
      --- ignored/old.txt
      +++ ignored/new.txt
      @@ -1 +1 @@
      -old
      +new
    PATCH

    result = plan(source, patch)

    assert_predicate result, :applied?
    assert_equal "new\n", result.new_text
  end

  def test_multiple_target_files_are_rejected
    source = "old\n"
    patch = <<~PATCH
      --- a/first
      +++ b/first
      @@ -1 +1 @@
      -old
      +one
      --- a/second
      +++ b/second
      @@ -1 +1 @@
      -old
      +two
    PATCH

    result = plan(source, patch)

    assert_equal "invalid", result.status
    assert_equal "multiple_targets", result.reasons.first.code
    assert_equal source, result.new_text
  end
end
