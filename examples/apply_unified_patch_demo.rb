# frozen_string_literal: true

# Demonstration for Diff::LCS.apply_unified_patch.
#
# Run with:
#   ruby -Ilib examples/apply_unified_patch_demo.rb

require "diff/lcs"

original = ["alpha", "SAME", "alpha", "SAME", "alpha"].join("\n") + "\n"

# A hunk whose context (SAME followed by the changed alpha) appears twice in
# the source. The header points at the midpoint, so both copies are equally
# far from the declared line and the planner cannot choose one uniquely.
ambiguous_patch = <<~PATCH
  @@ -3,2 +3,2 @@
   SAME
  -alpha
  +ALPHA
PATCH

# An additional hunk anchors on [alpha, SAME], which only occurs before the
# second copy of the repeated context. Combined with the first hunk there is
# exactly one compatible placement.
disambiguating_patch = <<~PATCH
  @@ -3,2 +3,2 @@
   alpha
   SAME
  @@ -3,2 +3,2 @@
   SAME
  -alpha
  +ALPHA
PATCH

def show(title, plan)
  puts title
  puts "  status: #{plan.status}"

  case plan.status
  when :ambiguous
    puts "  new_text: nil (original left unchanged)"
    plan.alternatives.each_with_index do |hunks, index|
      positions = hunks.map { |hunk| "hunk##{hunk.hunk_index} @ line #{hunk.old_start + 1}" }
      puts "  alternative #{index + 1}: #{positions.join(", ")}"
    end
  when :applied
    puts "  new_text:"
    plan.new_text.each_line { |line| puts "    #{line.chomp}" }
    puts "  hunk placements:"
    plan.hunks.each do |hunk|
      puts "    hunk##{hunk.hunk_index} lines #{hunk.old_start + 1}..#{hunk.old_end} " \
        "(offset #{hunk.offset}, fuzz #{hunk.fuzz})"
    end
    puts "  original -> new line mapping:"
    plan.mapping.each do |entry|
      if entry.nil?
        puts "    removed"
      else
        puts "    line #{entry.old_index + 1} -> line #{entry.new_index + 1} " \
          "(columns #{entry.start_column}...#{entry.end_column})"
      end
    end
  else
    plan.failures.each { |failure| puts "  #{failure.reason}: #{failure.detail}" }
  end

  puts
end

show("1) Two identical contexts -> ambiguous, original unchanged",
  Diff::LCS.apply_unified_patch(original, ambiguous_patch))

show("2) Added hunk makes the joint placement unique",
  Diff::LCS.apply_unified_patch(original, disambiguating_patch))

show("3) Rejecting the drift with max_offset: 0",
  Diff::LCS.apply_unified_patch(original, ambiguous_patch, max_offset: 0))
