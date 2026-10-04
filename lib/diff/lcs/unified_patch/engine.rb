# frozen_string_literal: true

class Diff::LCS::UnifiedPatch
  # Hard safety limit on the number of solver nodes explored while proving
  # uniqueness. Real patches contain few candidates; this only guards against
  # pathological input built from pathological repetitions.
  MAX_SEARCH_NODES = 200_000

  # Hard limit on candidate locations enumerated for a single hunk.
  MAX_CANDIDATES_PER_HUNK = 500

  Options = Data.define(:max_offset, :max_fuzz, :line_ending) do
    def self.build(max_offset: nil, fuzz: 0, line_ending: :preserve)
      new(max_offset, fuzz, line_ending)
    end
  end

  # Locates every compatible way to place each hunk, independently.
  #
  # Returns `[candidate_sets, failures]`. Candidate sets are Arrays (one per
  # hunk) of `[fuzz, anchor_start, anchor_end]` triples, ordered cheapest
  # first. Failures are FailedHunk objects for hunks that cannot be located at
  # all.
  def self.enumerate(hunks, source_lines, options)
    failures = []
    sets = hunks.map.with_index do |hunk, hunk_index|
      variants(hunk, source_lines, options, hunk_index, failures)
    end

    [sets, failures]
  end

  def self.variants(hunk, source_lines, options, hunk_index, failures)
    declared = declared_anchor(hunk)
    old_tokens = hunk.tokens.reject { |kind,| kind == :insert }

    matches = []

    leading_context = old_tokens.take_while { |kind,| kind == :context }.size
    trailing_context = old_tokens.reverse.take_while { |kind,| kind == :context }.size
    has_change = hunk.tokens.any? { |kind,| kind != :context }

    # Like `patch -F n`: up to n leading and up to n trailing context lines may
    # be ignored independently. Retained old-side lines must still match as a
    # contiguous block, so surrounding context cannot silently mismatch.
    max_trim = has_change ? options.max_fuzz : 0

    0.upto(max_trim) do |drop_lead|
      0.upto(max_trim) do |drop_trail|
        next if drop_lead > leading_context || drop_trail > trailing_context

        fuzz = drop_lead + drop_trail
        pattern = old_tokens[drop_lead...old_tokens.size - drop_trail] || []
        pattern_text = pattern.map { |_, text| text }

        each_occurrence(source_lines, pattern_text) do |anchor_start|
          anchor_end = anchor_start + pattern_text.size
          offset = anchor_start - (declared + drop_lead)

          next if options.max_offset && offset.abs > options.max_offset
          next unless newline_markers_accept?(hunk, fuzz, anchor_start, anchor_end, source_lines)

          matches << Candidate.new(
            hunk_index, anchor_start, anchor_end, fuzz, offset, drop_lead, drop_trail
          )
        end
      end
    end

    # Keep the cheapest variants but never exceed the hard enumeration cap.
    matches.sort_by! { |candidate| [candidate.fuzz, candidate.offset.abs, candidate.anchor_start] }
    matches = matches.first(MAX_CANDIDATES_PER_HUNK)

    if matches.empty?
      failures << FailedHunk.new(
        hunk_index,
        options.max_offset ? :offset_exceeded : :no_match,
        "no context-anchored location found for hunk ##{hunk_index + 1} " \
          "(@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@)",
        []
      )
    end

    matches
  end
  private_class_method :variants

  # Zero-based index in the source where the hunk header claims the hunk
  # begins. Unified diff uses line 0 (and count 0) to anchor insertions at the
  # very beginning of the file.
  def self.declared_anchor(hunk)
    # With an empty old range (pure insertion), the header's start is the
    # 1-based line *before* which the insertion occurs. Line 0 is used for
    # insertion at the very beginning of the file.
    # For a normal hunk this is the 0-based index of the first old line. For a
    # pure insertion it is the 0-based position at which the insert lands
    # (line 0 with count 0 means the very beginning).
    hunk.old_count.zero? ? hunk.old_start : hunk.old_start - 1
  end
  private_class_method :declared_anchor

  def self.each_occurrence(source_lines, pattern_text)
    return if source_lines.size < pattern_text.size

    if pattern_text.empty?
      0.upto(source_lines.size) { |position| yield position }
      return
    end

    first = pattern_text.first
    last_start = source_lines.size - pattern_text.size

    0.upto(last_start) do |start|
      next unless source_lines[start].text == first

      match = pattern_text.each_with_index.all? do |wanted, offset|
        source_lines[start + offset].text == wanted
      end

      yield start if match
    end
  end
  private_class_method :each_occurrence

  # Validates `\\ No newline at end of file` markers against a concrete
  # placement. The markers describe physical end-of-file conditions, so a
  # hunk carrying them can only match at the end of the source and the located
  # final source line must actually lack a terminator.
  def self.newline_markers_accept?(hunk, fuzz, anchor_start, anchor_end, source_lines)
    if hunk.old_missing_newline
      return false if hunk.old_count.zero? || anchor_end.zero?

      last_source_index = anchor_end - 1
      return false unless last_source_index == source_lines.size - 1
      return false if source_lines[last_source_index].terminator
    end

    if hunk.new_missing_newline
      at_end = hunk.old_count.zero? ? anchor_start == source_lines.size : anchor_end == source_lines.size
      return false unless at_end

      # When the located hunk reaches EOF, the old-side marker (or the final
      # context line) must agree that the source ends without a terminator.
      last_source_index = anchor_end - 1
      return false if last_source_index && source_lines[last_source_index]&.terminator
    end

    true
  end
  private_class_method :newline_markers_accept?

  # Jointly chooses one placement per hunk such that no two hunks consume the
  # same source lines (no greedy double-selection of repeated text), preferring
  # less dropped context and then smaller total absolute offset.
  #
  # Returns `[status, best_plans, search_failure]` where +best_plans+ contains
  # the distinct minimum-cost placements (one for `:unique`, two or more for
  # `:ambiguous`).
  def self.solve(candidate_sets, hunks)
    return [:failed, [], nil] if candidate_sets.any?(&:empty?)

    ordered_sets = candidate_sets.map do |set|
      set.sort_by { |candidate| [candidate.fuzz, candidate.offset.abs, candidate.anchor_start] }
    end

    search = Search.new(ordered_sets, hunks)
    search.run
  end

  def self.build_hunk_plans(placements, hunks)
    placements.map do |candidate|
      hunk = hunks[candidate.hunk_index]

      HunkPlan.new(
        candidate.hunk_index,
        candidate.anchor_start,
        candidate.anchor_end,
        declared_anchor(hunk),
        candidate.offset,
        candidate.fuzz,
        hunk.tokens,
        hunk.old_missing_newline,
        hunk.new_missing_newline,
        candidate.dropped_leading,
        candidate.dropped_trailing
      )
    end
  end
  private_class_method :build_hunk_plans

  # Depth-first joint placement search with cost-based pruning.
  class Search # :nodoc: all
    def initialize(ordered_sets, hunks)
      @sets = ordered_sets
      @hunks = hunks
      @best = nil
      @best_cost = nil
      @tie = nil
      @nodes = 0
    end

    def run
      limited = visit(0, [], 0, 0, 0)

      if limited
        return [
          :failed, [],
          FailedHunk.new(
            nil, :search_limit,
            "exceeded #{MAX_SEARCH_NODES} nodes while proving uniqueness", []
          )
        ]
      end

      return [:failed, [], nil] if @best.nil?

      plans = [@best, @tie].compact.map do |placements|
        Diff::LCS::UnifiedPatch.send(:build_hunk_plans, placements, @hunks)
      end

      [@tie.nil? ? :unique : :ambiguous, plans, nil]
    end

    private

    # Returns true when the search was abandoned for exceeding the node limit.
    def visit(index, placements, cursor, fuzz_total, offset_total)
      @nodes += 1
      return true if @nodes > MAX_SEARCH_NODES

      if index == @sets.size
        cost = [fuzz_total, offset_total]

        if cheaper?(cost, @best_cost)
          @best_cost = cost
          @best = placements.dup
          @tie = nil
        elsif cost == @best_cost && placements != @best && @tie.nil?
          @tie = placements.dup
        end

        return false
      end

      # Fuzz never decreases deeper in the tree, so prune hopeless branches.
      return false if @best_cost && fuzz_total > @best_cost.first

      @sets[index].each do |candidate|
        next if candidate.anchor_start < cursor

        placements << candidate
        limited = visit(
          index + 1, placements, candidate.anchor_end,
          fuzz_total + candidate.fuzz, offset_total + candidate.offset.abs
        )
        placements.pop

        return true if limited
        break unless @tie.nil? # one proven tie is enough for ambiguity
      end

      false
    end

    def cheaper?(cost, best)
      best.nil? || (cost <=> best) == -1
    end
  end
end
