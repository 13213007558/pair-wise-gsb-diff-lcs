# frozen_string_literal: true

# An analysis of every optimal alignment between two sequences.
#
# Two sequences such as +%w[a b a]+ and +%w[a a b]+ frequently have more than one
# equally short edit script (equivalently, more than one maximum-length common
# subsequence alignment). Picking any single one of them and presenting it as "the"
# diff is misleading for tooling such as audit UIs. This analysis separates what is
# *certain* from what is *ambiguous*:
#
# - A <b>certain match</b> is a pair of positions +[seq1_index, seq2_index]+ that is
#   matched in <b>every</b> optimal alignment. Certainty is computed exactly from the
#   dynamic programming tables, not by intersecting a sample of alignments, so it is
#   unaffected by the display +limit+.
#
# - A position is <b>ambiguous</b> when it is matched in some but not all optimal
#   alignments (or is matched to different partners in different optimal alignments).
#   Ambiguous positions are grouped into <b>ambiguous regions</b> bounded by certain
#   matches, which a UI can highlight directly.
#
# - Up to +limit+ distinct optimal alignments are enumerated for display, in a fixed
#   canonical order. The limit only controls how many alignments are displayed; it
#   never changes the certainty conclusions.
#
# All matches are reported as pairs of original indexes, so repeated values are
# distinguished by position rather than by value.
#
# Analysis is bounded by a <b>state budget</b> (dynamic programming cells plus
# enumeration nodes). When the budget is exceeded, the analysis stops early and
# reports through #unproven exactly which conclusions could not be established;
# anything not listed there is exact.
#
# == Example
#
#   analysis = Diff::LCS.analyze_alignments(%w[a b a c], %w[a a b c])
#
#   analysis.lcs_length        # => 3
#   analysis.certain_matches   # => [[3, 3]] ("c" aligns with "c" in every optimal script)
#   analysis.ambiguous_a       # => [0, 1, 2]
#   analysis.ambiguous_b       # => [0, 1, 2]
#   analysis.ambiguous_regions # => [{a: 0...3, b: 0...3}]
#   analysis.alignments        # => [
#                              #      [[0, 0], [1, 2], [3, 3]],
#                              #      [[0, 0], [2, 1], [3, 3]],
#                              #      [[0, 1], [1, 2], [3, 3]]
#                              #    ]
#   analysis.complete?         # => true
#   analysis.unproven          # => []
class Diff::LCS::AlignmentAnalysis
  # The default maximum number of optimal alignments enumerated for display.
  DEFAULT_ALIGNMENT_LIMIT = 10

  # The default budget of states (dynamic programming cells plus enumeration nodes)
  # that an analysis may explore before stopping early.
  DEFAULT_STATE_BUDGET = 100_000

  # The length of a longest common subsequence between the two sequences. This is
  # +nil+ when it could not be proven within the state budget (see #unproven).
  attr_reader :lcs_length

  # The matched position pairs +[seq1_index, seq2_index]+ present in <b>every</b>
  # optimal alignment, sorted by index. This is computed exactly and independently of
  # the alignment display +limit+. It is +nil+ when unproven (see #unproven).
  attr_reader :certain_matches

  # The sorted indexes of the first sequence that are matched in some, but not all,
  # optimal alignments. It is +nil+ when unproven (see #unproven).
  attr_reader :ambiguous_a

  # The sorted indexes of the second sequence that are matched in some, but not all,
  # optimal alignments. It is +nil+ when unproven (see #unproven).
  attr_reader :ambiguous_b

  # Maximal spans between certain matches that still contain ambiguous positions, as
  # an array of +{a: range, b: range}+ hashes with exclusive-end ranges. It is +nil+
  # when unproven (see #unproven).
  attr_reader :ambiguous_regions

  # Up to +limit+ distinct optimal alignments, each an array of
  # +[seq1_index, seq2_index]+ pairs, enumerated in a fixed canonical (lexicographic)
  # order. When #complete? is false, this is a prefix of the full enumeration.
  attr_reader :alignments

  # The conclusions that could not be established within the state budget, as an array
  # of symbols drawn from +:lcs_length+, +:certain_matches+, +:ambiguity+, and
  # +:alignments+. Empty when every reported conclusion is exact.
  attr_reader :unproven

  # The number of states explored during the analysis.
  attr_reader :states_used

  # Why alignment enumeration stopped early: +:limit+ (more than +limit+ alignments
  # exist), +:budget+ (the state budget was exhausted), or +nil+ (the enumeration is
  # exhaustive).
  attr_reader :truncated_by

  # Analyze the optimal alignments between +seq1+ and +seq2+.
  #
  # - +limit+: the maximum number of optimal alignments enumerated for display.
  #   +nil+ enumerates all of them. This only affects #alignments; certainty
  #   conclusions are always computed exactly.
  # - +state_budget+: the maximum number of states explored. +nil+ means unlimited.
  def initialize(seq1, seq2, limit: DEFAULT_ALIGNMENT_LIMIT, state_budget: DEFAULT_STATE_BUDGET)
    @limit = limit
    @state_budget = state_budget
    @states_used = 0
    @unproven = []
    @truncated_by = nil
    @alignments = []

    analyze(seq1, seq2)
  end

  # Whether the enumeration of optimal alignments is exhaustive. When false, #alignments
  # holds only a prefix in canonical order and #truncated_by explains why.
  def complete? = @truncated_by.nil?

  # Whether the given conclusion (+:lcs_length+, +:certain_matches+, +:ambiguity+,
  # or +:alignments+) was established within the state budget.
  def proven?(conclusion) = !@unproven.include?(conclusion)

  # Whether any position of either sequence remains ambiguous. +nil+ when the
  # ambiguity analysis itself is unproven.
  def ambiguous?
    return nil unless proven?(:ambiguity)

    !@ambiguous_a.empty? || !@ambiguous_b.empty?
  end

  private

  def analyze(seq1, seq2)
    pref = lcs_prefix_lengths(seq1, seq2)
    suff = pref && lcs_suffix_lengths(seq1, seq2)

    if pref.nil? || suff.nil?
      @unproven = %i[lcs_length certain_matches ambiguity alignments]
      @truncated_by = :budget
      return
    end

    length = pref[seq1.size * (seq2.size + 1) + seq2.size]
    @lcs_length = length

    by_rank = feasible_pairs_by_rank(seq1, seq2, pref, suff, length)

    if by_rank.nil?
      @unproven = %i[certain_matches ambiguity alignments]
      @truncated_by = :budget
      return
    end

    classify_positions(seq1.size, seq2.size, by_rank)
    @ambiguous_regions = compute_regions(seq1.size, seq2.size)
    @alignments = enumerate_alignments(by_rank, length)
  end

  # Spend +states+ against the budget. Returns false when the budget is exhausted.
  def spend(states)
    @states_used += states
    @state_budget.nil? || @states_used <= @state_budget
  end

  # A flat (m + 1) x (n + 1) table where entry [i][j] is the LCS length of
  # seq1[0...i] and seq2[0...j]. Returns nil when the budget is exhausted.
  def lcs_prefix_lengths(seq1, seq2)
    n = seq2.size
    width = n + 1
    table = Array.new((seq1.size + 1) * width, 0)

    1.upto(seq1.size) do |i|
      return nil unless spend(n)

      ai = seq1[i - 1]
      row = i * width
      prev = row - width

      1.upto(n) do |j|
        table[row + j] =
          if ai == seq2[j - 1]
            table[prev + j - 1] + 1
          else
            left = table[row + j - 1]
            up = table[prev + j]
            (left > up) ? left : up
          end
      end
    end

    table
  end

  # A flat (m + 1) x (n + 1) table where entry [i][j] is the LCS length of
  # seq1[i..] and seq2[j..]. Returns nil when the budget is exhausted.
  def lcs_suffix_lengths(seq1, seq2)
    m = seq1.size
    n = seq2.size
    width = n + 1
    table = Array.new((m + 1) * width, 0)

    (m - 1).downto(0) do |i|
      return nil unless spend(n)

      ai = seq1[i]
      row = i * width
      below = row + width

      (n - 1).downto(0) do |j|
        table[row + j] =
          if ai == seq2[j]
            table[below + j + 1] + 1
          else
            right = table[row + j + 1]
            down = table[below + j]
            (right > down) ? right : down
          end
      end
    end

    table
  end

  # A pair (i, j) with seq1[i] == seq2[j] can be part of an optimal alignment exactly
  # when pref[i][j] + 1 + suff[i + 1][j + 1] equals the LCS length; its "rank" is
  # pref[i][j]. Every optimal alignment contains exactly one feasible pair per rank,
  # so a pair is matched in *every* optimal alignment exactly when it is the only
  # feasible pair at its rank. Returns feasible pairs grouped by rank (each group
  # sorted by index), or nil when the budget is exhausted.
  def feasible_pairs_by_rank(seq1, seq2, pref, suff, length)
    n = seq2.size
    width = n + 1
    by_rank = Array.new(length) { [] }

    seq1.size.times do |i|
      return nil unless spend(n)

      ai = seq1[i]
      base = i * width
      below = base + width

      n.times do |j|
        next unless ai == seq2[j]

        rank = pref[base + j]
        by_rank[rank] << [i, j] if rank + 1 + suff[below + j + 1] == length
      end
    end

    by_rank
  end

  def classify_positions(size_a, size_b, by_rank)
    feasible_a = Array.new(size_a, false)
    feasible_b = Array.new(size_b, false)
    certain_a = Array.new(size_a, false)
    certain_b = Array.new(size_b, false)
    @certain_matches = []

    by_rank.each do |pairs|
      pairs.each do |(i, j)|
        feasible_a[i] = true
        feasible_b[j] = true
      end

      next unless pairs.size == 1

      i, j = pairs.first
      @certain_matches << [i, j]
      certain_a[i] = true
      certain_b[j] = true
    end

    @ambiguous_a = []
    @ambiguous_b = []
    size_a.times { |i| @ambiguous_a << i if feasible_a[i] && !certain_a[i] }
    size_b.times { |j| @ambiguous_b << j if feasible_b[j] && !certain_b[j] }
  end

  def compute_regions(size_a, size_b)
    regions = []
    return regions if @ambiguous_a.empty? && @ambiguous_b.empty?

    a_lo = b_lo = 0

    (@certain_matches + [[size_a, size_b]]).each do |(ai, bi)|
      if spans_any?(a_lo...ai, @ambiguous_a) || spans_any?(b_lo...bi, @ambiguous_b)
        regions << {a: a_lo...ai, b: b_lo...bi}
      end

      a_lo = ai + 1
      b_lo = bi + 1
    end

    regions
  end

  def spans_any?(range, positions)
    positions.any? { |position| range.cover?(position) }
  end

  # Enumerate optimal alignments in canonical (lexicographic) order using iterative
  # depth-first search. Every feasible pair extends to at least one optimal alignment,
  # so no partial path can dead-end before reaching the full LCS length.
  def enumerate_alignments(by_rank, length)
    return [[]] if length.zero?

    alignments = []
    path = []
    frames = [by_rank[0].dup]
    minimums = [[0, 0]]

    until frames.empty?
      candidates = frames.last
      min_a, min_b = minimums.last
      chosen = nil

      until candidates.empty?
        unless spend(1)
          @truncated_by = :budget
          @unproven << :alignments
          return alignments
        end

        i, j = candidates.shift

        if i >= min_a && j >= min_b
          chosen = [i, j]
          break
        end
      end

      if chosen.nil?
        frames.pop
        minimums.pop
        path.pop
        next
      end

      if path.size == length - 1
        if @limit && alignments.size >= @limit
          @truncated_by = :limit
          return alignments
        end

        alignments << (path + [chosen])
      else
        path << chosen
        frames << by_rank[path.size].dup
        minimums << [chosen[0] + 1, chosen[1] + 1]
      end
    end

    alignments
  end
end

