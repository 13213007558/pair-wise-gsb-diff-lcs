# frozen_string_literal: true

require_relative "test_helper"

class TestCompose < Minitest::Test
  def compose(first, second, source_length) = Diff::LCS.compose(first, second, source_length:)

  def test_compose_insert_then_delete_cancels
    a = %w[a b]
    p = Diff::LCS.diff(a, %w[a x b])
    q = Diff::LCS.diff(%w[a x b], a)

    composed = compose(p, q, a.length)

    assert_empty composed.to_a
    assert_equal a, Diff::LCS.patch!(a, composed)
    assert_equal a.length, composed.result_length
  end

  def test_compose_delete_then_insert_at_same_position
    a = %w[a b c]
    p = Diff::LCS.diff(a, %w[a c])
    q = Diff::LCS.diff(%w[a c], %w[a z c])

    composed = compose(p, q, a.length)

    assert_equal %w[a z c], Diff::LCS.patch!(a, composed)
    assert_equal %w[a z c], Diff::LCS.patch(a, composed, :patch)

    changes = composed.to_a
    assert_equal 2, changes.size
    assert_equal ["+", 1, "z"], changes[0].to_a
    assert_equal [:second], changes[0].sources
    assert_equal ["-", 1, "b"], changes[1].to_a
    assert_equal [:first], changes[1].sources
  end

  def test_compose_second_patch_rewrites_first_patch_insertion
    a = %w[a b]
    p = Diff::LCS.diff(a, %w[a x b])
    q = Diff::LCS.sdiff(%w[a x b], %w[a y b])

    composed = compose(p, q, a.length)

    assert_equal %w[a y b], Diff::LCS.patch!(a, composed)

    changes = composed.to_a
    assert_equal 1, changes.size
    assert_equal ["+", 1, "y"], changes[0].to_a
    assert_equal %i[first second], changes[0].sources
  end

  def test_compose_second_patch_rewrites_first_patch_replacement
    a = %w[a b c]
    p = Diff::LCS.sdiff(a, %w[a x c])
    q = Diff::LCS.sdiff(%w[a x c], %w[a y c])

    composed = compose(p, q, a.length)

    assert_equal %w[a y c], Diff::LCS.patch!(a, composed)

    changes = composed.to_a
    assert_equal 1, changes.size
    change = changes[0]
    assert_instance_of Diff::LCS::ComposedContextChange, change
    assert_equal ["!", [1, "b"], [1, "y"]], change.to_a
    assert_equal %i[first second], change.sources
  end

  def test_compose_second_patch_deletes_first_patch_replacement
    a = %w[a b c]
    p = Diff::LCS.sdiff(a, %w[a x c])
    q = Diff::LCS.sdiff(%w[a x c], %w[a c])

    composed = compose(p, q, a.length)

    assert_equal %w[a c], Diff::LCS.patch!(a, composed)

    changes = composed.to_a
    assert_equal 1, changes.size
    assert_equal ["-", 1, "b"], changes[0].to_a
    assert_equal %i[first second], changes[0].sources
  end

  def test_compose_delete_in_unmodified_region_preserves_claimed_element
    a = %w[a b c]
    p = Diff::LCS.diff(a, a)
    q = Diff::LCS.diff(a, %w[a c])

    composed = compose(p, q, a.length)

    assert_equal %w[a c], Diff::LCS.patch!(a, composed)

    changes = composed.to_a
    assert_equal 1, changes.size
    # The original element cannot be verified during composition (the composer never
    # sees the sequence), so the element claimed by the second patch is preserved
    # explicitly as a precondition instead of being blanked out.
    assert_equal ["-", 1, "b"], changes[0].to_a
    refute_equal "", changes[0].element
    refute_nil changes[0].element
    assert_equal [:second], changes[0].sources
  end

  def test_compose_replace_in_unmodified_region_preserves_claimed_element
    a = %w[a b c]
    p = Diff::LCS.diff(a, a)
    q = Diff::LCS.sdiff(a, %w[a z c])

    composed = compose(p, q, a.length)

    assert_equal %w[a z c], Diff::LCS.patch!(a, composed)

    changes = composed.to_a
    assert_equal 1, changes.size
    change = changes[0]
    assert_instance_of Diff::LCS::ComposedContextChange, change
    assert_equal ["!", [1, "b"], [1, "z"]], change.to_a
    refute_equal "", change.old_element
    refute_nil change.old_element
    assert_equal [:second], change.sources
  end

  def test_compose_records_provenance_of_each_change
    a = %w[a b c d]
    p = Diff::LCS.diff(a, %w[a x c d])
    q = Diff::LCS.diff(%w[a x c d], %w[y a x d])

    composed = compose(p, q, a.length)

    assert_equal %w[y a x d], Diff::LCS.patch!(a, composed)

    sources_of = ->(action, element) {
      composed.find { |change| change.action == action && change.element == element }.sources
    }

    assert_equal [:second], sources_of.call("+", "y")
    assert_equal [:first], sources_of.call("+", "x")
    assert_equal [:first], sources_of.call("-", "b")
    assert_equal [:second], sources_of.call("-", "c")
  end

  def test_compose_result_applies_through_existing_interface
    a = %w[a b c d e]
    b = %w[x a c e]
    c = %w[x a z e y]
    p = Diff::LCS.diff(a, b)
    q = Diff::LCS.diff(b, c)

    composed = compose(p, q, a.length)

    assert_equal c, Diff::LCS.patch!(a, composed)
    assert_equal c, Diff::LCS.patch(a, composed, :patch)
    assert_equal c, Diff::LCS.patch(a, composed)
    assert_equal c, Diff::LCS.patch(a, composed.to_a)
    assert_equal a, Diff::LCS.unpatch!(Diff::LCS.patch!(a, composed), composed)
  end

  def test_compose_accepts_array_representations_and_hunks
    a = %w[a b]
    p = [[["+", 1, "x"]]]
    q = [["-", 1, "x"], ["+", 1, "y"]]

    composed = compose(p, q, a.length)

    assert_equal %w[a y b], Diff::LCS.patch!(a, composed)
  end

  def test_compose_rejects_inconsistent_second_patch
    p = [["+", 0, "x"]]
    q = [["-", 0, "y"]]

    assert_raises(ArgumentError) { compose(p, q, 1) }
  end

  def test_compose_rejects_first_patch_exceeding_source_length
    p = [["-", 5, "b"]]

    assert_raises(ArgumentError) { compose(p, [], 3) }
  end

  def test_compose_exhaustive_small_sequences_with_diff
    assert_composition_exhaustive(4) { |s1, s2| Diff::LCS.diff(s1, s2) }
  end

  def test_compose_exhaustive_small_sequences_with_sdiff
    assert_composition_exhaustive(3) { |s1, s2| Diff::LCS.sdiff(s1, s2) }
  end

  def test_compose_exhaustive_small_sequences_with_context_diff
    assert_composition_exhaustive(3) { |s1, s2|
      Diff::LCS.diff(s1, s2, Diff::LCS::ContextDiffCallbacks)
    }
  end

  def test_compose_does_not_expand_huge_unmodified_region
    huge = 10**12
    # B is "x" followed by the (unknown) contents of A; C deletes B[6] (which is A[5])
    # and appends "y" at the start. The unmodified region is only known by length; if
    # composition tried to expand it into individual elements, this test could never
    # finish.
    p = [["+", 0, "x"]]
    q = [["+", 0, "y"], ["-", 6, "q"]]

    composed = compose(p, q, huge)

    assert_equal huge, composed.source_length
    assert_equal huge + 1, composed.middle_length
    assert_equal huge + 1, composed.result_length

    changes = composed.to_a
    assert_equal 3, changes.size
    assert_equal ["+", 0, "y"], changes[0].to_a
    assert_equal [:second], changes[0].sources
    assert_equal ["+", 1, "x"], changes[1].to_a
    assert_equal [:first], changes[1].sources
    assert_equal ["-", 5, "q"], changes[2].to_a
    assert_equal [:second], changes[2].sources
  end

  private

  def assert_composition_exhaustive(max_length)
    sequences = (0..max_length).flat_map { |n| %w[a b].repeated_permutation(n).to_a }

    sequences.each do |a|
      sequences.each do |b|
        p = yield(a, b)

        sequences.each do |c|
          q = yield(b, c)
          composed = compose(p, q, a.length)

          assert_equal(
            Diff::LCS.patch!(Diff::LCS.patch!(a, p), q),
            Diff::LCS.patch!(a, composed),
            "compose failed for #{a.inspect} -> #{b.inspect} -> #{c.inspect}"
          )
          assert_equal c.length, composed.result_length
        end
      end
    end
  end
end
