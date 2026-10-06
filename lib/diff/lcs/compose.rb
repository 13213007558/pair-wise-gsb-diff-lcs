# frozen_string_literal: true

# A change in a composed patchset. Behaves exactly like Diff::LCS::Change (so it can be
# applied with Diff::LCS.patch, Diff::LCS.patch!, and Diff::LCS.unpatch!), but also
# records the provenance of the change: which of the composed patchsets it originates
# from.
class Diff::LCS::ComposedChange < Diff::LCS::Change
  # The patchsets this change originates from. Always a frozen array containing
  # +:first+ (the A->B patchset), +:second+ (the B->C patchset), or both.
  attr_reader :sources

  def initialize(action:, position:, element:, sources:)
    @sources = sources.freeze
    super(action:, position:, element:)
  end

  def ==(other) = super && sources == other.sources

  def inspect(*_args) = "#<#{self.class}: #{to_a.inspect} sources=#{sources.inspect}>"
end

# A contextual change in a composed patchset. Behaves exactly like
# Diff::LCS::ContextChange, but also records the provenance of the change. See
# Diff::LCS::ComposedChange.
class Diff::LCS::ComposedContextChange < Diff::LCS::ContextChange
  # The patchsets this change originates from. Always a frozen array containing
  # +:first+ (the A->B patchset), +:second+ (the B->C patchset), or both.
  attr_reader :sources

  def initialize(action:, old_position:, old_element:, new_position:, new_element:, sources:)
    @sources = sources.freeze
    super(action:, old_position:, old_element:, new_position:, new_element:)
  end

  def ==(other) = super && sources == other.sources

  def inspect(*_args) = "#<#{self.class}: #{to_a.inspect} sources=#{sources.inspect}>"
end

# The result of composing two patchsets with Diff::LCS.compose. A composed patchset is
# an enumerable sequence of Diff::LCS::ComposedChange and
# Diff::LCS::ComposedContextChange objects and can be handed directly to the existing
# application interface (Diff::LCS.patch, Diff::LCS.patch!, Diff::LCS.unpatch!, or the
# Diff::LCS mixin methods).
class Diff::LCS::ComposedPatch
  include Enumerable

  # The length of the original sequence (A), as declared when composing.
  attr_reader :source_length

  # The length of the intermediate sequence (B), derived from the first patchset.
  attr_reader :middle_length

  # The length of the resulting sequence (C), derived from both patchsets.
  attr_reader :result_length

  def initialize(changes, source_length:, middle_length:, result_length:) # :nodoc:
    @changes = changes.freeze
    @source_length = source_length
    @middle_length = middle_length
    @result_length = result_length
  end

  def each(&) = @changes.each(&)

  def to_a = @changes.dup

  def size = @changes.size

  def empty? = @changes.empty?

  def ==(other)
    other.is_a?(Diff::LCS::ComposedPatch) &&
      to_a == other.to_a &&
      source_length == other.source_length &&
      middle_length == other.middle_length &&
      result_length == other.result_length
  end

  def inspect = "#<#{self.class}: #{@changes.inspect}>"
end

# Composes two sequential patchsets into a single patchset without materializing the
# intermediate sequence.
#
# A version store holding only the patches A->B (+first+) and B->C (+second+) can
# produce the patch A->C directly, given the length of A (+source_length+). The
# sequences themselves are never required: unmodified regions are carried through the
# composition as symbolic intervals (offset + length), so composition cost depends on
# the number of changes, not on the size of the sequences.
#
# Changes in the composed patchset record their provenance through +#sources+: whether
# they originate from the +first+ patchset, the +second+ patchset, or both (for
# example, when the second patchset rewrites an element inserted by the first).
#
# Elements that the composed patchset removes or replaces are carried over from the
# source changes. Where such an element falls inside a region that the first patchset
# left unmodified, its value cannot be verified during composition (the original
# sequence is unknown); the element claimed by the second patchset is preserved
# verbatim as an explicit precondition of the composed change instead of being dropped
# or blanked out.
module Diff::LCS::Compose
  # A half-open interval of the original sequence carried unchanged through both
  # patchsets. Only the offset and length are tracked; the contents are never
  # materialized.
  Keep = Data.define(:start, :length)

  # A single literal element of the intermediate sequence introduced by a patchset.
  # +sources+ records which patchsets contributed the element. When the element
  # replaces an element of the original sequence (a "!" change), +replaced_position+
  # and +replaced_element+ describe that original element.
  Lit = Data.define(:element, :sources, :replaced_position, :replaced_element)

  # The removal of an original element at +position+. +element+ is the removed element
  # as claimed by the patchset that removed it.
  Deletion = Data.define(:position, :element, :sources)

  FIRST = [:first].freeze # :nodoc:
  SECOND = [:second].freeze # :nodoc:

  private_constant :Keep, :Lit, :Deletion, :FIRST, :SECOND

  class << self
    # Composes +first+ (A->B) and +second+ (B->C) into a Diff::LCS::ComposedPatch
    # describing A->C. +source_length+ is the length of A. Both patchsets may be any
    # patchset accepted by Diff::LCS.patch (Diff::LCS::Change or
    # Diff::LCS::ContextChange objects, their array representations, or hunks thereof).
    def compose(first, second, source_length)
      _, first_changes = Diff::LCS::Internals.analyze_patchset(first)
      _, second_changes = Diff::LCS::Internals.analyze_patchset(second)

      spans, deletions, middle_length = expand_first(first_changes, source_length)
      spans, result_length = apply_second(second_changes, spans, deletions, middle_length)
      changes = emit(spans, deletions)

      Diff::LCS::ComposedPatch.new(
        changes,
        source_length: source_length,
        middle_length: middle_length,
        result_length: result_length
      )
    end

    private

    # Walks the first patchset (A->B), describing the intermediate sequence B as a list
    # of Keep/Lit spans. Returns the spans, the deletions of original elements, and the
    # length of B.
    def expand_first(changes, source_length)
      spans = []
      deletions = []
      a_cursor = 0
      b_cursor = 0

      keep = lambda do |from, to|
        next if to == from

        if to < from
          fail ArgumentError, "the first patchset is not in source order"
        end

        last = spans.last
        if last.is_a?(Keep) && last.start + last.length == from
          spans[-1] = Keep.new(last.start, last.length + to - from)
        else
          spans << Keep.new(from, to - from)
        end
      end

      insert = lambda do |element, new_position|
        gap = new_position - b_cursor

        if gap.negative?
          fail ArgumentError, "the first patchset is not in sequence order"
        end

        keep.call(a_cursor, a_cursor + gap)
        a_cursor += gap
        b_cursor = new_position + 1
        spans << Lit.new(element, FIRST, nil, nil)
      end

      changes.each do |change|
        case change
        when Diff::LCS::ContextChange
          case change.action
          when "-"
            keep.call(a_cursor, change.old_position)
            b_cursor += change.old_position - a_cursor
            a_cursor = change.old_position + 1
            deletions << Deletion.new(change.old_position, change.old_element, FIRST)
          when "+"
            insert.call(change.new_element, change.new_position)
          when "!"
            keep.call(a_cursor, change.old_position)
            b_cursor += change.old_position - a_cursor + 1
            a_cursor = change.old_position + 1
            spans << Lit.new(change.new_element, FIRST, change.old_position, change.old_element)
          when "="
            keep.call(a_cursor, change.old_position + 1)
            b_cursor += change.old_position + 1 - a_cursor
            a_cursor = change.old_position + 1
          else
            fail ArgumentError, "cannot compose change with action #{change.action.inspect}"
          end
        when Diff::LCS::Change
          case change.action
          when "-"
            keep.call(a_cursor, change.position)
            b_cursor += change.position - a_cursor
            a_cursor = change.position + 1
            deletions << Deletion.new(change.position, change.element, FIRST)
          when "+"
            insert.call(change.element, change.position)
          when "="
            keep.call(a_cursor, change.position + 1)
            b_cursor += change.position + 1 - a_cursor
            a_cursor = change.position + 1
          else
            fail ArgumentError, "cannot compose change with action #{change.action.inspect}"
          end
        end
      end

      if a_cursor > source_length
        fail ArgumentError, "the first patchset exceeds the declared source length"
      end

      keep.call(a_cursor, source_length)
      b_cursor += source_length - a_cursor

      [spans, deletions, b_cursor]
    end

    # Walks the second patchset (B->C) over the span description of B, producing the
    # span description of C. Deletions of original elements are appended to
    # +deletions+. Returns the new spans and the length of C.
    def apply_second(changes, spans, deletions, middle_length)
      out = []
      index = 0
      offset = 0
      b_cursor = 0
      c_cursor = 0

      emit_keep = lambda do |start, length|
        last = out.last
        if last.is_a?(Keep) && last.start + last.length == start
          out[-1] = Keep.new(last.start, last.length + length)
        else
          out << Keep.new(start, length)
        end
      end

      # Moves +count+ elements of B across to the output, keeping Keep spans symbolic.
      take = lambda do |count|
        if count.negative?
          fail ArgumentError, "the second patchset is not in sequence order"
        end

        b_cursor += count
        c_cursor += count

        while count.positive?
          span = spans[index]

          if span.nil?
            fail ArgumentError, "the second patchset exceeds the result of the first"
          end

          if span.is_a?(Keep)
            take_n = [count, span.length - offset].min
            emit_keep.call(span.start + offset, take_n)
            offset += take_n
            if offset == span.length
              index += 1
              offset = 0
            end
            count -= take_n
          else
            out << span
            index += 1
            count -= 1
          end
        end
      end

      # Removes the current element of B. Removing an element inside a Keep span
      # becomes a deletion of the corresponding original element; the claimed element
      # is preserved as an explicit, otherwise unverifiable precondition. Removing a
      # literal cancels the insertion that created it (an insertion by the first
      # patchset simply vanishes; a replacement collapses back to the deletion of the
      # original element).
      drop = lambda do |claimed|
        span = spans[index]

        if span.nil?
          fail ArgumentError, "the second patchset exceeds the result of the first"
        end

        if span.is_a?(Keep)
          deletions << Deletion.new(span.start + offset, claimed, SECOND)
          offset += 1
          if offset == span.length
            index += 1
            offset = 0
          end
        else
          unless span.element == claimed
            fail ArgumentError, "the second patchset does not apply to the result of the first"
          end

          if span.replaced_position
            deletions << Deletion.new(span.replaced_position, span.replaced_element, span.sources | SECOND)
          end

          index += 1
        end
      end

      # Replaces the current element of B with +element+.
      replace = lambda do |claimed, element|
        span = spans[index]

        if span.nil?
          fail ArgumentError, "the second patchset exceeds the result of the first"
        end

        if span.is_a?(Keep)
          out << Lit.new(element, SECOND, span.start + offset, claimed)
          offset += 1
          if offset == span.length
            index += 1
            offset = 0
          end
        else
          unless span.element == claimed
            fail ArgumentError, "the second patchset does not apply to the result of the first"
          end

          out << Lit.new(element, span.sources | SECOND, span.replaced_position, span.replaced_element)
          index += 1
        end
      end

      changes.each do |change|
        case change
        when Diff::LCS::ContextChange
          case change.action
          when "-"
            take.call(change.old_position - b_cursor)
            drop.call(change.old_element)
            b_cursor = change.old_position + 1
          when "+"
            take.call(change.new_position - c_cursor)
            out << Lit.new(change.new_element, SECOND, nil, nil)
            c_cursor += 1
          when "!"
            take.call(change.old_position - b_cursor)
            replace.call(change.old_element, change.new_element)
            b_cursor = change.old_position + 1
            c_cursor += 1
          when "="
            take.call(change.old_position + 1 - b_cursor)
            b_cursor = change.old_position + 1
          else
            fail ArgumentError, "cannot compose change with action #{change.action.inspect}"
          end
        when Diff::LCS::Change
          case change.action
          when "-"
            take.call(change.position - b_cursor)
            drop.call(change.element)
            b_cursor = change.position + 1
          when "+"
            take.call(change.position - c_cursor)
            out << Lit.new(change.element, SECOND, nil, nil)
            c_cursor += 1
          when "="
            take.call(change.position + 1 - b_cursor)
            b_cursor = change.position + 1
          else
            fail ArgumentError, "cannot compose change with action #{change.action.inspect}"
          end
        end
      end

      take.call(middle_length - b_cursor)

      [out, c_cursor]
    end

    # Emits the composed changes from the span description of C and the collected
    # deletions, in an order that Diff::LCS.patch can apply.
    def emit(spans, deletions)
      changes = []
      deletions = deletions.sort_by(&:position)
      d = 0
      c_cursor = 0

      emit_deletions = lambda do |before|
        while d < deletions.size && deletions[d].position < before
          deletion = deletions[d]
          changes << Diff::LCS::ComposedChange.new(
            action: "-", position: deletion.position, element: deletion.element,
            sources: deletion.sources
          )
          d += 1
        end
      end

      spans.each do |span|
        if span.is_a?(Keep)
          emit_deletions.call(span.start)
          c_cursor += span.length
        elsif span.replaced_position
          emit_deletions.call(span.replaced_position)
          changes << Diff::LCS::ComposedContextChange.new(
            action: "!",
            old_position: span.replaced_position,
            old_element: span.replaced_element,
            new_position: c_cursor,
            new_element: span.element,
            sources: span.sources
          )
          c_cursor += 1
        else
          changes << Diff::LCS::ComposedChange.new(
            action: "+", position: c_cursor, element: span.element, sources: span.sources
          )
          c_cursor += 1
        end
      end

      emit_deletions.call(deletions.empty? ? 0 : deletions.last.position + 1)

      changes
    end
  end
end

module Diff::LCS
  # Composes two sequential patchsets into a single patchset. Given a patchset +first+
  # that turns sequence A into sequence B and a patchset +second+ that turns B into C,
  # returns a Diff::LCS::ComposedPatch that turns A into C directly, without requiring
  # the intermediate sequence B. +source_length+ is the length of A.
  #
  #   first = Diff::LCS.diff(a, b)
  #   second = Diff::LCS.diff(b, c)
  #   composed = Diff::LCS.compose(first, second, source_length: a.length)
  #   Diff::LCS.patch!(a, composed) # => c
  #
  # Each change of the composed patchset records which patchset(s) it originates from
  # through its +#sources+ attribute (+:first+, +:second+, or both).
  #
  # See Diff::LCS::Compose for details.
  def self.compose(first, second, source_length:)
    Diff::LCS::Compose.compose(first, second, source_length)
  end
end
