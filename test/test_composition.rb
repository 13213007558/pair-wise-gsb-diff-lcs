# frozen_string_literal: true

require_relative "test_helper"

class TestComposition < Minitest::Test
  include Diff::LCS::TestHelper

  def _test_exhaustive_small_sequence_composition
    alphabet = [nil, 0, 1, 2]
    sequences = 0.upto(3).flat_map do |length|
      Array.new(length) { alphabet }.inject([[]]) do |products, values|
        products.flat_map { |product| values.map { |value| product + [value] } }
      end
    end

    sequences.each do |a|
      sequences.each do |b|
        first_patch = diff(a, b)
        sequences.each do |c|
          second_patch = diff(b, c)
          composed = Diff::LCS.compose(first_patch, second_patch, source_length: a.length)

          assert_equal(c, Diff::LCS.patch!(a, composed))
        end
      end
    end
  end

  def test_insert_then_delete_at_the_same_place
    a = ["middle"]
    b = ["inserted", "middle"]
    c = ["middle"]
    first = [[Diff::LCS::Change.new("+", 0, "inserted")]]
    second = [[Diff::LCS::Change.new("-", 0, "inserted")]]
    composed = Diff::LCS.compose(first, second, source_length: a.length)

    assert_equal(c, Diff::LCS.patch!(a, composed))
    assert_equal([:second], composed.grep(Diff::LCS::ComposedChange).flat_map(&:sources).compact.first)
  end

  def test_delete_then_insert_at_the_same_place
    a = ["old"]
    b = []
    c = ["new"]
    first = [[Diff::LCS::Change.new("-", 0, "old")]]
    second = [[Diff::LCS::Change.new("+", 0, "new")]]
    composed = Diff::LCS.compose(first, second, source_length: a.length)

    assert_equal(c, Diff::LCS.patch!(a, composed))
  end

  def test_second_patch_modifies_element_added_by_first_patch
    a = []
    b = ["draft"]
    c = ["final"]
    first = [[Diff::LCS::Change.new("+", 0, "draft")]]
    second = [[Diff::LCS::Change.new("-", 0, "draft"), Diff::LCS::Change.new("+", 0, "final")]]
    composed = Diff::LCS.compose(first, second, source_length: a.length)

    assert_equal(c, Diff::LCS.patch!(a, composed))
    assert_equal([:first, :second], composed.find { |change| change.action == "+" }.sources)
  end

  def test_unverified_precondition_is_retained_without_treating_nil_as_empty_string
    a = []
    b = []
    c = []
    second = [[Diff::LCS::ContextChange.new("-", 0, nil, nil, nil)]]
    composed = Diff::LCS.compose([], second, source_length: 0)

    assert_equal(c, Diff::LCS.patch!(a, composed))
    refute_empty(composed.preconditions)
    assert_equal(false, composed.preconditions.first.verified)
  end

  def test_huge_unchanged_interval_uses_length_only
    huge_length = 10_000_000_000
    a = Object.new
    def a.size = 10_000_000_002
    def a.[](argument)
      raise "large interval expanded" if argument.respond_to?(:size) && argument.size > 2
    end

    first = [[
      Diff::LCS::Change.new("-", 0, :head),
      Diff::LCS::Change.new("-", huge_length + 1, :tail)
    ]]
    second = [[]]
    composed = Diff::LCS.compose(first, second, source_length: a.size)
    interval = composed.grep(Diff::LCS::UnchangedInterval).first

    assert_equal(huge_length, interval.length)
    assert_equal([interval], composed.select { |change| change.is_a?(Diff::LCS::UnchangedInterval) && change.length > 2 })
    refute(composed.any? { |change| change.action == "=" && !change.is_a?(Diff::LCS::UnchangedInterval) })
  end
end
