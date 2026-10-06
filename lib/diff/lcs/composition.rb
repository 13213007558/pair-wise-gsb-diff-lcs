# frozen_string_literal: true

require "diff/lcs"

class Diff::LCS::ComposedChange < Diff::LCS::ContextChange
  def to_a
    [action, [old_position, old_element], [new_position, new_element]]
  end
end

class Diff::LCS::UnchangedInterval < Diff::LCS::ComposedChange
  class << self
    def new(old_position, new_position, length)
      allocate.tap do |instance|
        instance.send(:initialize, old_position, new_position, length)
      end
    end
  end

  def initialize(old_position, new_position, length)
    super(action: "=", old_position: old_position, old_element: nil,
          new_position: new_position, new_element: nil,
          sources: nil, length: length)
  end

  def self.[](old_position, new_position, length)
    new(old_position, new_position, length)
  end
end

class Diff::LCS::ComposedPatch < Array
  attr_reader :source_length, :target_length, :preconditions

  def initialize(changes, source_length:, target_length:, preconditions:)
    super(changes)
    @source_length = source_length
    @target_length = target_length
    @preconditions = preconditions
  end
end

class << Diff::LCS
  def compose(first, second, source_length:)
    Diff::LCS::PatchComposer.new(source_length).compose(first, second)
  end
end

class Diff::LCS::PatchComposer
  FIRST = :first
  SECOND = :second
  private_constant :FIRST, :SECOND

  Original = Data.define(:start, :length)
  Inserted = Data.define(:element, :sources)
  Deleted = Data.define(:position, :element, :sources)
  Precondition = Data.define(:sequence, :position, :expected, :verified)

  def initialize(source_length)
    @source_length = source_length
  end

  def compose(first, second)
    @b = [Original.new(0, @source_length)]
    @deletions = []
    @preconditions = []

    apply_first(first)
    buckets = Hash.new { |hash, key| hash[key] = [] }
    apply_second(second, buckets)

    changes = build_changes(buckets)
    target_length = @source_length + count_actions(first, "+") - count_actions(first, "-") +
      count_actions(second, "+") - count_actions(second, "-")

    Diff::LCS::ComposedPatch.new(
      changes,
      source_length: @source_length,
      target_length: target_length,
      preconditions: @preconditions
    )
  end

  private

  def count_actions(patchset, action)
    _, changes = Diff::LCS::Internals.analyze_patchset(patchset)
    changes.count { |change| change.action == action }
  end

  def apply_first(patchset)
    each_change(patchset) do |action, old_position, old_element, new_position, new_element|
      case action
      when "-" then first_delete(old_position, old_element)
      when "+" then first_insert(new_position, new_element)
      when "!"
        first_delete(old_position, old_element)
        first_insert(new_position, new_element)
      end
    end
  end

  def apply_second(patchset, buckets)
    changes = normalized_changes(patchset)
    consumed = {}

    changes.each_with_index do |change, index|
      next if consumed[index]

      action, old_position, old_element, new_position, new_element = change
      pair = changes[index + 1]

      if action == "-" && pair&.first == "+" && pair[3] == new_position
        second_replace(old_position, old_element, pair[4], buckets)
        consumed[index + 1] = true
      elsif action == "+" && pair&.first == "-" && pair[3] == new_position
        second_replace(pair[1], pair[2], new_element, buckets)
        consumed[index + 1] = true
      elsif action == "-"
        second_delete(old_position, old_element, buckets)
      elsif action == "+"
        buckets[new_position] << new_element
      elsif action == "!"
        second_replace(old_position, old_element, new_element, buckets)
      end
    end
  end

  def each_change(patchset)
    _, changes = Diff::LCS::Internals.analyze_patchset(patchset)
    changes.each do |change|
      if change.is_a?(Diff::LCS::ContextChange)
        yield(change.action, change.old_position, change.old_element,
              change.new_position, change.new_element)
      else
        case change.action
        when "-" then yield("-", change.position, change.element, nil, nil)
        when "+" then yield("+", nil, nil, change.position, change.element)
        when "=" then yield("=", change.position, change.element, change.position, change.element)
        end
      end
    end
  end

  def normalized_changes(patchset)
    result = []
    each_change(patchset) do |action, old_position, old_element, new_position, new_element|
      result << if action == "-"
        [action, old_position, old_element, old_position, nil]
      elsif action == "+"
        [action, nil, nil, new_position, new_element]
      else
        [action, old_position, old_element, new_position, new_element]
      end
    end
    result
  end

  def locate(position)
    offset = 0
    @b.each_with_index do |segment, index|
      size = segment_size(segment)
      if segment.is_a?(Original)
        if position >= segment.start && position < segment.start + size
          return [index, position - segment.start]
        end
      elsif position < offset + size
        return [index, position - offset]
      end

      offset += size
    end
    [@b.length, 0]
  end

  def segment_size(segment)
    segment.is_a?(Original) ? segment.length : 1
  end

  def split(index, offset)
    segment = @b[index]
    return unless segment.is_a?(Original) && offset.positive?

    @b[index, 1] = [
      Original.new(segment.start, offset),
      Original.new(segment.start + offset, segment.length - offset)
    ]
  end

  def first_insert(position, element)
    index, offset = locate(position)
    split(index, offset)
    index += 1 if offset.positive?
    @b.insert(index, Inserted.new(element, [FIRST]))
  end

  def first_delete(position, element)
    index, offset = locate(position)
    split(index, offset)
    index += 1 if offset.positive?
    segment = @b.fetch(index)
    @b[index] = Deleted.new(position, element, [FIRST]) if segment.is_a?(Inserted)
    replace_original(index, offset, element, [FIRST]) if segment.is_a?(Original)
  end

  def second_insert(position, element, buckets)
    buckets[position] << element
  end

  def second_delete(position, element, buckets)
    index, offset = locate(position)
    split(index, offset)
    index += 1 if offset.positive?
    return @preconditions << Precondition.new(:intermediate, position, element, false) unless @b[index]

    segment = @b.fetch(index)

    case segment
    when Inserted
      verify_inserted(segment, element, position)
      @b.delete_at(index)
      buckets[position].each do |inserted|
        @b.insert(index, Inserted.new(inserted, [SECOND]))
        index += 1
      end
    when Original
      replace_original(index, offset, element, [SECOND])
    when Deleted
      @preconditions << Precondition.new(:intermediate, position, element, false)
    end
  end

  def second_replace(position, expected, new_element, buckets)
    index, offset = locate(position)
    split(index, offset)
    index += 1 if offset.positive?
    segment = @b.fetch(index)

    case segment
    when Inserted
      verify_inserted(segment, expected, position)
      @b[index] = Inserted.new(new_element, (segment.sources + [SECOND]).uniq)
    when Original
      replace_original(index, offset, expected, [SECOND])
      first_insert(position, new_element)
    when Deleted
      @preconditions << Precondition.new(:intermediate, position, expected, false)
    end
  end

  def replace_original(index, offset, element, sources)
    segment = @b.fetch(index)
    absolute = segment.start + offset
    @b[index] = Deleted.new(absolute, element, sources)
  end

  def verify_inserted(segment, expected, position)
    if expected.nil?
      @preconditions << Precondition.new(:intermediate, position, nil, false)
    elsif expected != segment.element
      raise ArgumentError, "precondition mismatch at #{position}: #{expected.inspect} != #{segment.element.inspect}"
    else
      @preconditions << Precondition.new(:intermediate, position, expected, true)
    end
  end

  def build_changes(buckets)
    changes = []
    old_position = new_position = 0
    b_position = 0

    emit_insert = lambda do |element, sources|
      changes << Diff::LCS::ComposedChange.new("+", nil, nil, new_position, element, sources)
      new_position += 1
    end
    emit_delete = lambda do |element, sources|
      changes << Diff::LCS::ComposedChange.new("-", old_position, element, nil, nil, sources)
      old_position += 1
    end
    emit_unchanged = lambda do |length|
      return unless length.positive?
      return if length == 1 && changes.last&.action == "="

      changes << Diff::LCS::UnchangedInterval.new(old_position, new_position, length)
      old_position += length
      new_position += length
    end

    emit_bucket = lambda do |index|
      entries = buckets.keys.select { |key| key < index }.sort.flat_map { |key| buckets[key] }
      limit = index.infinite? ? Float::INFINITY : index + 1
      same = buckets[index] || []
      entries.concat(index.infinite? ? same : same[0, limit])
      entries.each { |element| emit_insert.call(element, [SECOND]) }
      consumed = entries.dup
      buckets.keys.select { |key| key < index }.sort.each do |key|
        take = [consumed.length, buckets[key].length].min
        next unless take.positive?

        buckets[key].shift(take)
        consumed.shift(take)
      end
      if buckets[index]
        take = index.infinite? ? consumed.length : [consumed.length, index + 1].min
        buckets[index].shift(take)
        consumed.shift(take)
      end
      buckets.keys.each { |key| buckets.delete(key) if buckets[key]&.empty? }
    end

    @b.each do |segment|
      before_position = b_position
      case segment
      when Original
        emit_bucket.call(b_position)
        emit_unchanged.call(segment.length)
      when Inserted
        emit_bucket.call(b_position)
        emit_insert.call(segment.element, segment.sources)
      when Deleted
        emit_bucket.call(b_position)
        emit_delete.call(segment.element, segment.sources)
      end

      b_position += segment_size(segment)
    end

    emit_bucket.call(@b.empty? ? Float::INFINITY : b_position)
    tail = @source_length - old_position
    if tail.positive?
      emit_unchanged.call(tail)
    end
    emit_bucket.call(Float::INFINITY) unless buckets.empty?
    changes
  end
end
