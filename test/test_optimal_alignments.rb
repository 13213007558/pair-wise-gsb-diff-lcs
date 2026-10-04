# frozen_string_literal: true

require "minitest/autorun"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "diff/lcs"

class TestOptimalAlignments < Minitest::Test
  def test_repeated_values_distinguish_original_positions
    result = Diff::LCS.optimal_alignments(%i[a b a], %i[a a b], state_budget: 100)
    match_sets = [
      [[0, 0], [1, 2]],
      [[0, 0], [2, 1]],
      [[0, 1], [1, 2]]
    ]

    assert_proven(result)
    assert_equal 2, result[:optimal_match_count]
    assert_equal match_sets, result[:alignments].map { |alignment| match_set(alignment) }
    assert_empty result[:necessary_matches]
    assert_equal(match_sets.flatten(1).uniq.sort, pairs(result[:ambiguous_matches]))
    region_bounds = result[:ambiguous_regions].map {
      [
        _1[:old_position_start],
        _1[:old_position_end],
        _1[:new_position_start],
        _1[:new_position_end]
      ]
    }
    assert_equal [[0, 2, 0, 2]], region_bounds
  end

  def test_marks_uncertain_region_between_necessary_matches
    old_sequence = %i[x a b a z]
    new_sequence = %i[x a a b z]
    result = Diff::LCS.optimal_alignments(old_sequence, new_sequence, state_budget: 100)

    assert_proven(result)
    assert_equal [[0, 0], [4, 4]], pairs(result[:necessary_matches])
    assert_equal 3, result[:alignments].size
    assert_equal 1, result[:ambiguous_regions].size

    region = result[:ambiguous_regions].first
    assert_equal 1, region[:rank_start]
    assert_equal 2, region[:rank_end]
    assert_equal [1, 3], [region[:old_position_start], region[:old_position_end]]
    assert_equal [1, 3], [region[:new_position_start], region[:new_position_end]]
    assert_includes result[:certain_old_positions], 1
    assert_equal %i[x a b a z], result[:alignments].first[:rows].filter_map { _1[:old_element] }
    assert_equal %i[x a a b z], result[:alignments].first[:rows].filter_map { _1[:new_element] }
  end

  def test_limit_only_restricts_displayed_alignments
    old_sequence = %i[x a b a z]
    new_sequence = %i[x a a b z]
    result = Diff::LCS.optimal_alignments(old_sequence, new_sequence, limit: 1, state_budget: 100)

    assert_proven(result)
    assert result[:alignments_truncated]
    assert_equal 1, result[:alignments].size
    assert_equal [[0, 0], [4, 4]], pairs(result[:necessary_matches])
    assert_equal 4, result[:ambiguous_matches].size
  end

  def test_short_sequences_match_exhaustive_enumeration
    sequences = [
      %i[],
      %i[a],
      %i[b],
      %i[a a],
      %i[a b],
      %i[b a],
      %i[a b a],
      %i[a a b]
    ]

    sequences.each do |old_sequence|
      sequences.each do |new_sequence|
        result = Diff::LCS.optimal_alignments(
          old_sequence,
          new_sequence,
          limit: 100,
          state_budget: 1000
        )
        exhaustive = exhaustive_match_sets(old_sequence, new_sequence)
        possible_pairs = exhaustive.flatten(1).uniq.sort
        necessary_pairs = exhaustive.reduce(:&) || []

        assert_proven(result)
        assert_equal exhaustive, result[:alignments].map { |alignment| match_set(alignment) }
        assert_equal possible_pairs, pairs(result[:necessary_matches] + result[:ambiguous_matches])
        assert_equal necessary_pairs, pairs(result[:necessary_matches])
        assert_equal possible_pairs.map(&:first).uniq.sort, result[:possible_old_positions]
        assert_equal possible_pairs.map(&:last).uniq.sort, result[:possible_new_positions]
      end
    end
  end

  def test_state_budget_exceeded_does_not_claim_unproven_conclusions
    result = Diff::LCS.optimal_alignments(
      %i[x a b a z],
      %i[x a a b z],
      state_budget: 71
    )

    refute result[:proven]
    assert_equal "state_budget_exceeded", result[:proof_status]
    assert_equal 72, result[:states_required]
    assert_equal 1, result[:alignments].size
    assert_equal 4, result[:optimal_match_count]
    assert_empty result[:necessary_matches]
    assert_empty result[:ambiguous_matches]
    assert_empty result[:ambiguous_regions]
    assert_includes result[:unproven_conclusions], "necessary_matches"
    assert_includes result[:unproven_conclusions], "ambiguous_regions"
    assert_includes result[:unproven_conclusions], "possible_old_positions"
    assert_includes result[:unproven_conclusions], "ambiguous_new_positions"
    assert_nil result[:alignments_truncated]
  end

  def test_rejects_invalid_arguments
    assert_raises(ArgumentError) do
      Diff::LCS.optimal_alignments([], [], state_budget: "1")
    end

    assert_raises(ArgumentError) do
      Diff::LCS.optimal_alignments([], [], limit: -1, state_budget: 2)
    end

    assert_raises(ArgumentError) do
      Diff::LCS.optimal_alignments([], [], limit: 1, state_budget: -2)
    end
  end

  private

  def assert_proven(result)
    assert result[:proven]
    assert_equal "complete", result[:proof_status]
    refute_nil result[:alignments_truncated]
  end

  def pairs(matches)
    matches.map { |match| [match[:old_position], match[:new_position]] }.sort
  end

  def match_set(alignment)
    pairs(alignment[:matches])
  end

  def exhaustive_match_sets(old_sequence, new_sequence)
    possible_pairs = old_sequence.each_index.flat_map do |old_position|
      new_sequence.each_index.filter_map do |new_position|
        [old_position, new_position] if old_sequence[old_position] == new_sequence[new_position]
      end
    end

    longest = ([old_sequence.size, new_sequence.size].min).downto(0).find do |size|
      possible_pairs.combination(size).any? { |candidate| increasing?(candidate) }
    end

    possible_pairs
      .combination(longest)
      .select { |candidate| increasing?(candidate) }
      .to_a
  end

  def increasing?(pairs)
    pairs.each_cons(2).all? do |(left_old, left_new), (right_old, right_new)|
      right_old > left_old && right_new > left_new
    end
  end
end
