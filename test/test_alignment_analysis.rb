# frozen_string_literal: true

require_relative "test_helper"

class TestAlignmentAnalysis < Minitest::Test
  def analyze(...) = Diff::LCS.analyze_alignments(...)

  def test_reports_certain_matches_and_ambiguous_region
    analysis = analyze(%w[a b a c], %w[a a b c])

    assert_equal 3, analysis.lcs_length
    assert_equal [[3, 3]], analysis.certain_matches
    assert_equal [0, 1, 2], analysis.ambiguous_a
    assert_equal [0, 1, 2], analysis.ambiguous_b
    assert_equal [{a: 0...3, b: 0...3}], analysis.ambiguous_regions
    assert_equal [
      [[0, 0], [1, 2], [3, 3]],
      [[0, 0], [2, 1], [3, 3]],
      [[0, 1], [1, 2], [3, 3]]
    ], analysis.alignments
    assert_predicate analysis, :complete?
    assert_nil analysis.truncated_by
    assert_empty analysis.unproven
    assert_predicate analysis, :ambiguous?
  end

  def test_swappable_duplicates_have_no_certain_matches
    analysis = analyze(%w[a b a], %w[a a b])

    assert_equal 2, analysis.lcs_length
    assert_empty analysis.certain_matches
    assert_equal [0, 1, 2], analysis.ambiguous_a
    assert_equal [0, 1, 2], analysis.ambiguous_b
    assert_equal [{a: 0...3, b: 0...3}], analysis.ambiguous_regions
    assert_equal 3, analysis.alignments.size
  end

  def test_matches_distinguish_repeated_values_by_position
    analysis = analyze(%w[a a], %w[a a])

    assert_equal [[0, 0], [1, 1]], analysis.certain_matches
    assert_equal [[[0, 0], [1, 1]]], analysis.alignments
    refute_predicate analysis, :ambiguous?
    assert_empty analysis.ambiguous_regions
  end

  def test_identical_sequences_are_fully_certain
    analysis = analyze(%w[a b a], %w[a b a])

    assert_equal [[0, 0], [1, 1], [2, 2]], analysis.certain_matches
    assert_empty analysis.ambiguous_a
    assert_empty analysis.ambiguous_b
    assert_empty analysis.ambiguous_regions
    assert_equal [[[0, 0], [1, 1], [2, 2]]], analysis.alignments
  end

  def test_empty_sequences
    analysis = analyze([], [])

    assert_equal 0, analysis.lcs_length
    assert_empty analysis.certain_matches
    assert_equal [[]], analysis.alignments
    assert_predicate analysis, :complete?
    assert_empty analysis.unproven
  end

  def test_sequences_without_common_elements
    analysis = analyze(%w[a a], %w[b b])

    assert_equal 0, analysis.lcs_length
    assert_empty analysis.certain_matches
    assert_equal [[]], analysis.alignments
    assert_predicate analysis, :complete?
  end

  def test_works_on_strings
    analysis = analyze("abac", "aabc")

    assert_equal 3, analysis.lcs_length
    assert_equal [[3, 3]], analysis.certain_matches
    assert_equal [{a: 0...3, b: 0...3}], analysis.ambiguous_regions
  end

  def test_limit_only_controls_displayed_alignments
    analysis = analyze(%w[a b a c], %w[a a b c], limit: 1)

    assert_equal 1, analysis.alignments.size
    refute_predicate analysis, :complete?
    assert_equal :limit, analysis.truncated_by

    # The certain matches are exact even though only one alignment is displayed:
    # intersecting the displayed alignments would wrongly claim every pair certain.
    displayed_intersection = analysis.alignments.reduce(:&)
    assert_equal 3, displayed_intersection.size
    assert_equal [[3, 3]], analysis.certain_matches
    assert_empty analysis.unproven
  end

  def test_limit_zero_displays_no_alignments
    analysis = analyze(%w[a b a c], %w[a a b c], limit: 0)

    assert_empty analysis.alignments
    assert_equal :limit, analysis.truncated_by
    assert_equal [[3, 3]], analysis.certain_matches
  end

  def test_limit_at_exact_alignment_count_is_complete
    analysis = analyze(%w[a b a c], %w[a a b c], limit: 3)

    assert_equal 3, analysis.alignments.size
    assert_predicate analysis, :complete?
  end

  def test_zero_budget_proves_nothing
    analysis = analyze(%w[a b a c], %w[a a b c], state_budget: 0)

    assert_nil analysis.lcs_length
    assert_nil analysis.certain_matches
    assert_nil analysis.ambiguous_a
    assert_nil analysis.ambiguous_b
    assert_nil analysis.ambiguous_regions
    assert_empty analysis.alignments
    assert_equal :budget, analysis.truncated_by
    refute_predicate analysis, :complete?
    assert_nil analysis.ambiguous?
    assert_equal %i[lcs_length certain_matches ambiguity alignments].sort, analysis.unproven.sort
    refute analysis.proven?(:lcs_length)
  end

  def test_budget_exhausted_during_feasibility_scan
    # 32 states cover both dynamic programming tables (2 * 4 * 4) but not the
    # feasibility scan, so only the LCS length is proven.
    analysis = analyze(%w[a b a c], %w[a a b c], state_budget: 47)

    assert_equal 3, analysis.lcs_length
    assert analysis.proven?(:lcs_length)
    assert_nil analysis.certain_matches
    assert_equal :budget, analysis.truncated_by
    assert_equal %i[certain_matches ambiguity alignments].sort, analysis.unproven.sort
  end

  def test_budget_exhausted_during_enumeration_keeps_certainty
    # 48 states cover the tables and the feasibility scan (3 * 4 * 4); enumeration
    # then has no room, but certainty conclusions remain exact.
    analysis = analyze(%w[a b a c], %w[a a b c], state_budget: 48)

    assert_equal 3, analysis.lcs_length
    assert_equal [[3, 3]], analysis.certain_matches
    assert_equal [0, 1, 2], analysis.ambiguous_a
    assert_empty analysis.alignments
    assert_equal :budget, analysis.truncated_by
    refute_predicate analysis, :complete?
    assert_equal [:alignments], analysis.unproven
    assert analysis.proven?(:certain_matches)
    refute analysis.proven?(:alignments)
  end

  def test_unlimited_budget_and_limit
    analysis = analyze(%w[a b a c], %w[a a b c], limit: nil, state_budget: nil)

    assert_predicate analysis, :complete?
    assert_equal 3, analysis.alignments.size
  end

  def test_results_are_deterministic
    first = analyze(%w[a b a c b], %w[b a a c b])
    second = analyze(%w[a b a c b], %w[b a a c b])

    assert_equal first.alignments, second.alignments
    assert_equal first.alignments, first.alignments.sort
    assert_equal first.certain_matches, second.certain_matches
  end

  def test_instance_method_when_extended
    seq = %w[a b a c]
    seq.extend(Diff::LCS)

    assert_equal [[3, 3]], seq.analyze_alignments(%w[a a b c]).certain_matches
  end

  # Exhaustively enumerates every optimal alignment with an independent
  # implementation, as ground truth for short sequences.
  def brute_force_alignments(a, b)
    memo = {}
    lcs = lambda do |i, j|
      if i >= a.size || j >= b.size
        0
      elsif memo[[i, j]]
        memo[[i, j]]
      else
        memo[[i, j]] =
          if a[i] == b[j]
            1 + lcs.call(i + 1, j + 1)
          else
            [lcs.call(i + 1, j), lcs.call(i, j + 1)].max
          end
      end
    end

    length = lcs.call(0, 0)
    alignments = []
    walk = lambda do |i, j, acc|
      if acc.size == length
        alignments << acc
      elsif i < a.size && j < b.size && acc.size + lcs.call(i, j) >= length
        walk.call(i + 1, j + 1, acc + [[i, j]]) if a[i] == b[j] && acc.size + 1 + lcs.call(i + 1, j + 1) == length
        walk.call(i + 1, j, acc)
        walk.call(i, j + 1, acc)
      end
    end
    walk.call(0, 0, [])

    [length, alignments.uniq]
  end

  def assert_analysis_matches_brute_force(a, b)
    length, expected = brute_force_alignments(a, b)
    analysis = analyze(a, b, limit: nil, state_budget: nil)

    assert_equal length, analysis.lcs_length, "lcs_length for #{a.inspect} vs #{b.inspect}"
    assert_predicate analysis, :complete?
    assert_empty analysis.unproven

    assert_equal expected.sort, analysis.alignments.sort, "alignments for #{a.inspect} vs #{b.inspect}"
    assert_equal analysis.alignments.sort, analysis.alignments, "canonical order for #{a.inspect} vs #{b.inspect}"

    analysis.alignments.each do |alignment|
      assert_equal length, alignment.size
      alignment.each_cons(2) do |(i1, j1), (i2, j2)|
        assert_operator i1, :<, i2
        assert_operator j1, :<, j2
      end
      alignment.each { |(i, j)| assert_equal a[i], b[j] }
    end

    certain = expected.reduce(:&) || []
    assert_equal certain.sort, analysis.certain_matches, "certain matches for #{a.inspect} vs #{b.inspect}"

    matched_a = expected.flat_map { |al| al.map(&:first) }.uniq
    matched_b = expected.flat_map { |al| al.map(&:last) }.uniq
    assert_equal (matched_a - certain.map(&:first)).sort, analysis.ambiguous_a,
      "ambiguous_a for #{a.inspect} vs #{b.inspect}"
    assert_equal (matched_b - certain.map(&:last)).sort, analysis.ambiguous_b,
      "ambiguous_b for #{a.inspect} vs #{b.inspect}"

    covered = analysis.ambiguous_regions.flat_map { |region| region[:a].to_a }
    assert (analysis.ambiguous_a - covered).empty?, "ambiguous positions must be inside a region"
    analysis.ambiguous_regions.each do |region|
      assert (certain.map(&:first) & region[:a].to_a).empty?
      assert (certain.map(&:last) & region[:b].to_a).empty?
    end
  end

  def sequences(alphabet, max_length)
    [[]] + (1..max_length).flat_map { |len| alphabet.repeated_permutation(len).to_a }
  end

  def test_exhaustive_short_sequences_binary_alphabet
    seqs = sequences(%w[a b], 4)
    seqs.each do |a|
      seqs.each { |b| assert_analysis_matches_brute_force(a, b) }
    end
  end

  def test_exhaustive_short_sequences_ternary_alphabet
    seqs = sequences(%w[a b c], 3)
    seqs.each do |a|
      seqs.each { |b| assert_analysis_matches_brute_force(a, b) }
    end
  end
end

