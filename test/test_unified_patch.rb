# frozen_string_literal: true

require_relative "test_helper"

class TestUnifiedPatch < Minitest::Test
  REPEATED = ["alpha", "SAME", "alpha", "SAME", "alpha"].join("\n") + "\n"

  AMBIGUOUS_PATCH = <<~PATCH
    @@ -3,2 +3,2 @@
     SAME
    -alpha
    +ALPHA
  PATCH

  # The added hunk matches [alpha, SAME], which only appears immediately
  # before the second copy of the repeated [SAME, alpha] context.
  DISAMBIGUATING_PATCH = <<~PATCH
    @@ -3,2 +3,2 @@
     alpha
     SAME
    @@ -3,2 +3,2 @@
     SAME
    -alpha
    +ALPHA
  PATCH

  def apply_patch(...)
    Diff::LCS.apply_unified_patch(...)
  end

  def test_applies_a_straightforward_hunk_and_returns_mapping
    original = "header\nkeep me\nmarker\n"
    patch = <<~PATCH
      @@ -1,3 +1,3 @@
       header
      -keep me
      +keep you
       marker
    PATCH

    result = apply_patch(original, patch)

    assert_predicate result, :applied?
    assert_equal "header\nkeep you\nmarker\n", result.new_text
    assert_equal original, result.original_text
    assert_equal [0, 2], result.mapping.values_at(0, 2).map(&:new_index)
    assert_nil result.mapping[1]
    assert_equal 0, result.hunks.first.offset
  end

  def test_two_identical_contexts_produce_an_ambiguous_plan
    result = apply_patch(REPEATED, AMBIGUOUS_PATCH)

    assert_predicate result, :ambiguous?
    assert_nil result.new_text
    assert_equal 2, result.alternatives.size

    starts = result.alternatives.map { |hunks| hunks.first.old_start }
    assert_equal [1, 3], starts
    assert_equal [-1, 1], result.alternatives.map { |hunks| hunks.first.offset }
  end

  def test_adding_a_hunk_uniquely_determines_the_location
    ambiguous = apply_patch(REPEATED, AMBIGUOUS_PATCH)
    resolved = apply_patch(REPEATED, DISAMBIGUATING_PATCH)

    assert_predicate ambiguous, :ambiguous?
    assert_predicate resolved, :applied?
    assert_equal [0, 3], resolved.hunks.map(&:old_start)
    assert_equal "alpha\nSAME\nalpha\nSAME\nALPHA\n", resolved.new_text
  end

  def test_max_offset_rejects_too_distant_locations
    result = apply_patch(REPEATED, AMBIGUOUS_PATCH, max_offset: 0)

    assert_predicate result, :failed?
    assert_equal :offset_exceeded, result.failures.first.reason
    assert_nil result.new_text
  end

  def test_shift_within_max_offset_applies
    shifted = "new docs line\n" + REPEATED
    unique_patch = "@@ -4,3 +4,3 @@\n SAME\n-alpha\n+ALPHA\n SAME\n"

    # [SAME, alpha, SAME] identifies the second copy uniquely.
    shifted_plan = apply_patch(shifted, unique_patch, max_offset: 2)

    assert_predicate shifted_plan, :applied?
    assert_equal(-1, shifted_plan.hunks.first.offset)
    assert_equal "new docs line\nalpha\nSAME\nALPHA\nSAME\nalpha\n",
      shifted_plan.new_text
  end

  def test_fuzz_ignores_context_lines
    # Authored against [old ctx, changed, old ctx]; the live file has different
    # surrounding context, so only the changed line anchors with fuzz 1.
    source = "new intro\nkeep\nnew outro\n"
    patch = <<~PATCH
      @@ -1,3 +1,3 @@
       old intro
      -keep
      +kept!
       old outro
    PATCH

    assert_predicate apply_patch(source, patch, fuzz: 0), :failed?

    result = apply_patch(source, patch, fuzz: 1)

    assert_predicate result, :applied?
    assert_equal 2, result.hunks.first.fuzz
    assert_equal 1, result.hunks.first.dropped_leading
    assert_equal 1, result.hunks.first.dropped_trailing
    assert_equal "new intro\nkept!\nnew outro\n", result.new_text
    assert_nil result.mapping[1]
  end

  def test_hunks_cannot_both_select_the_same_repeated_text
    source = "x\nTOKEN\nx\nTOKEN\nx\n"
    patch = <<~PATCH
      @@ -2,1 +2,1 @@
      -TOKEN
      +FIRST
      @@ -4,1 +4,1 @@
      -TOKEN
      +SECOND
    PATCH

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal [[1, 2], [3, 4]], result.hunks.map { |h| [h.old_start, h.old_end] }
    assert_equal "x\nFIRST\nx\nSECOND\nx\n", result.new_text
  end

  def test_crlf_is_preserved
    source = "a\r\nb\r\n"
    patch = "@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\r\nB\r\n", result.new_text
  end

  def test_missing_newline_at_end_of_file_is_preserved
    source = "a\nb"
    patch = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n\\ No newline at end of file\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\nB", result.new_text
  end

  def test_missing_newline_marker_must_match_actual_end_of_file
    source = "a\nb\n"
    patch = "@@ -1,2 +1,2 @@\n a\n-b\n+B\n\\ No newline at end of file\n"

    result = apply_patch(source, patch)

    assert_predicate result, :failed?
  end

  def test_empty_context_lines_are_supported
    source = "\na\n"
    patch = "@@ -1,2 +1,1 @@\n \n-a\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "\n", result.new_text
  end

  def test_coordinate_mapping_reports_content_columns
    source = "header\nkeep me\nmarker\n"
    patch = "@@ -2,1 +2,1 @@\n-keep me\n+keep you\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?

    marker = result.mapping.fetch(2)
    assert_equal 2, marker.new_index
    assert_equal "marker\n".bytesize - 1, marker.end_column - marker.start_column
    assert_equal "marker", result.new_text.byteslice(marker.start_column, marker.end_column - marker.start_column)
  end

  def test_malformed_patch_is_reported_without_changing_anything
    result = apply_patch("a\n", "@@ -1,2 +1,1 @@\n a\n")

    assert_predicate result, :failed?
    assert_equal :malformed_hunk, result.failures.first.reason
    assert_nil result.new_text
  end

  def test_patch_without_hunks_fails
    result = apply_patch("a\n", "--- a/x\n+++ b/x\n")

    assert_predicate result, :failed?
    assert_equal :no_hunks, result.failures.first.reason
  end

  def test_patch_paths_are_never_touched
    path = File.join(Dir.tmpdir, "diff-lcs-must-not-exist-#{Process.pid}")
    refute File.exist?(path)

    patch = "--- a/#{File.basename(path)}\n+++ b/#{File.basename(path)}\n@@ -1,1 +1,1 @@\n-a\n+b\n"

    result = apply_patch("a\n", patch)

    assert_predicate result, :applied?
    refute File.exist?(path)
  end

  def test_pure_insertion_hunk
    source = "a\nc\n"
    # `-2,0` is the boundary after line 2 (git convention for insert hunks).
    patch = "@@ -2,0 +2,1 @@\n+b\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\nc\nb\n", result.new_text
    assert_equal [0, 1], result.mapping.map(&:new_index)
  end

  def test_pure_insertion_between_lines
    source = "a\nc\n"
    # Context anchors the insertion between line 1 and line 2.
    patch = "@@ -1,1 +1,2 @@\n a\n+b\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "a\nb\nc\n", result.new_text
    assert_equal [0, 2], result.mapping.map(&:new_index)
  end

  def test_insertion_into_empty_file
    patch = "@@ -0,0 +1 @@\n+only line\n"

    result = apply_patch("", patch)

    assert_predicate result, :applied?
    assert_equal "only line\n", result.new_text
    assert_equal [], result.mapping
  end

  def test_insertion_without_final_newline
    source = ""
    patch = "@@ -0,0 +1 @@\n+only line\n" + "\\ No newline at end of file\n"

    result = apply_patch(source, patch)

    assert_predicate result, :applied?
    assert_equal "only line", result.new_text
  end

  def test_original_object_is_not_mutated
    source = +"a\nb\n"
    original = source.dup
    patch = "@@ -1,1 +1,1 @@\n-a\n+A\n"

    apply_patch(source, patch)

    assert_equal original, source
  end
end
