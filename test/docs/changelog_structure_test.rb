# frozen_string_literal: true

require_relative "../test_helper"

# [unit] STRUCTURE guard for CHANGELOG.md. It lives under test/docs/ because its
# SUBJECT is a prose file rather than any behaviour of the gem — the same reason
# bin/dor-check counts a test/docs/*_test.rb file as documentation work rather
# than as a behavioural change. It asserts the file's SHAPE, never its
# prose — no assertion here names an entry, a feature or a word, so ordinary
# changelog writing cannot turn it red.
#
# WHY IT EXISTS. Between v0.5.2 and v0.9.1 this file's newest heading stayed at
# `## v0.5.0` while thirteen releases went out, because `bin/release prepare`
# bumped `lib/solana_studio/version.rb` and its lockfile but never rolled the
# `## Unreleased` bucket into a version heading — and nothing failed when it
# didn't. Forty-four shipped entries accumulated under a heading that said they
# had not shipped. This guard is the thing that would have gone red at the second
# release instead of the fourteenth.
#
# THE FLOOR IS A PROPERTY, NOT A COUNT, and that is deliberate. A structure test
# whose regex has stopped matching passes having proved nothing, so the obvious
# guard is a minimum heading count — but a hard-coded floor copied between repos
# is the same vacuous pass wearing a number: set it near the current count and it
# never fires again as the file grows past it. The floor here is derived from the file itself
# on every run: EVERY `## ` heading below the bucket must parse as a version. If
# the regex ever stops matching this repo's dialect, every heading becomes
# unparseable at once and this fails loudly — there is no number to copy wrong
# and no way for the parsed set to collapse quietly to zero.
class ChangelogStructureTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CHANGELOG_PATH = File.join(ROOT, "CHANGELOG.md")

  UNRELEASED = "## Unreleased"

  # THIS repo's one heading dialect: a `v`-prefixed version and a parenthesised
  # ISO date. Deliberately stricter than the cross-repo regex the pending hub
  # guard will carry (`Release::Changelog::VERSION_HEADING` in mcritchie-studio
  # PR #1344, unmerged — it accepts an optional `v` and optional brackets so it
  # also reads studio-engine's `## 0.39.0 — 2026-08-11` and turf-vault's
  # `## [0.25.0] - 2026-06-10`), because a second dialect landing in THIS file is
  # the defect: the roller copies the dialect it finds, so one foreign heading
  # propagates to every heading written after it.
  VERSION_HEADING = /\A\#\# v(\d+\.\d+\.\d+) \(\d{4}-\d{2}-\d{2}\)\z/

  # How far `SolanaStudio::VERSION` may run ahead of the newest version heading
  # before the file counts as carrying a backlog rather than a gap. NOT ZERO: a
  # release that ships no entry at all is legitimate (v0.8.0, v0.9.0 and v0.9.1
  # were three such, and each carries an entry-less heading recording exactly
  # that). Two is chosen to match the value the PENDING hub guard will carry —
  # `Release::Changelog::MAX_MINOR_DRIFT = 2`, in mcritchie-studio PR #1344
  # (`release-prepare-skips-changelog`), which is not merged, so no such constant
  # exists on the hub today. This is a HAND-COPIED number: nothing tests that the
  # two agree, and if the hub's value changes this one will not follow. Re-check
  # it by hand when that PR lands, and treat any disagreement as this file being
  # stale rather than the conductor being wrong.
  MAX_MINOR_DRIFT = 2

  def setup
    @lines = File.readlines(CHANGELOG_PATH, chomp: true)
    @headings = @lines.each_with_index.filter_map do |line, i|
      next unless line.start_with?("## ")

      { line: line, number: i + 1 }
    end
  end

  # The derived floor. Runs first because every other assertion here reads
  # `parsed_versions`, and a broken parse makes all of them vacuous.
  def test_every_heading_below_the_bucket_parses_as_a_version
    refute_empty @headings, "no '## ' headings found at all — the parse is broken, not the file"

    unparsed = @headings.reject { |h| h[:line] == UNRELEASED }
                        .reject { |h| version_of(h[:line]) }
    assert_empty unparsed.map { |h| "line #{h[:number]}: #{h[:line]}" },
                 "every '## ' heading below '#{UNRELEASED}' must read '## vX.Y.Z (YYYY-MM-DD)'"

    # The floor, derived: one heading is the bucket, every other one is a
    # version. Stated as an equality so it moves with the file and can never go
    # stale the way a copied constant does.
    assert_equal @headings.size - 1, parsed_versions.size,
                 "#{parsed_versions.size} of #{@headings.size} headings parsed as versions; " \
                 "expected all but the '#{UNRELEASED}' bucket"
  end

  def test_unreleased_appears_once_and_leads_the_file
    occurrences = @headings.select { |h| h[:line] == UNRELEASED }
    assert_equal 1, occurrences.size,
                 "expected exactly one '#{UNRELEASED}' heading, found #{occurrences.size}"
    assert_equal @headings.first[:number], occurrences.first[:number],
                 "'#{UNRELEASED}' must be the first '## ' heading; found " \
                 "#{@headings.first[:line].inspect} above it"
  end

  def test_version_headings_are_strictly_decreasing
    parsed_versions.each_cons(2) do |(a_line, a_ver), (b_line, b_ver)|
      assert_operator (a_ver <=> b_ver), :>, 0,
                      "version headings must decrease down the file, but line #{a_line} " \
                      "(#{a_ver.join('.')}) is not above line #{b_line} (#{b_ver.join('.')})"
    end
  end

  def test_no_version_appears_twice
    seen = parsed_versions.map { |_line, ver| ver.join(".") }
    duplicates = seen.tally.select { |_v, n| n > 1 }.keys
    assert_empty duplicates, "these versions carry more than one heading: #{duplicates.join(', ')}"
  end

  def test_every_subsection_sits_under_a_version_heading
    first_heading = @headings.map { |h| h[:number] }.min
    orphans = @lines.each_with_index.filter_map do |line, i|
      next unless line.start_with?("### ")
      next if (i + 1) > first_heading

      "line #{i + 1}: #{line}"
    end
    assert_empty orphans, "'### ' subsections found above the first '## ' heading"
  end

  # THE DRIFT GUARD — the one that would have caught the original defect, and the
  # only assertion here that bites on a file whose ORDER is fine and whose
  # BOOKKEEPING is not. A monotonic-order check passes on a fully backlogged
  # file; this one does not.
  #
  # `SolanaStudio::VERSION` is the version this tree carries; the newest version
  # heading is the newest release the changelog admits shipping. When the second
  # falls far behind the first, releases are going out while their entries sit
  # under Unreleased.
  def test_newest_heading_keeps_up_with_the_shipped_version
    newest = parsed_versions.first
    refute_nil newest, "no version heading to compare against SolanaStudio::VERSION"

    current = SolanaStudio::VERSION.split(".").map(&:to_i)
    _line, newest_version = newest

    assert_operator (current <=> newest_version), :>=, 0,
                    "the changelog's newest heading (#{newest_version.join('.')}) is AHEAD of " \
                    "SolanaStudio::VERSION (#{SolanaStudio::VERSION}) — a version was documented " \
                    "before it shipped"

    # A MAJOR bump has to be rolled at once — 1.0.0 shipping while the newest
    # heading still reads 0.9.x is the same defect at a louder scale — so a
    # differing major is refused outright rather than converted into a minor
    # count that would read as nonsense.
    major_gap = current[0] - newest_version[0]
    drift = major_gap.zero? ? current[1] - newest_version[1] : nil
    behind = drift ? "#{drift} minor version(s)" : "a whole major version"
    assert drift && drift <= MAX_MINOR_DRIFT,
           "SolanaStudio::VERSION is #{SolanaStudio::VERSION} but the newest changelog heading is " \
           "#{newest_version.join('.')} — #{behind} of entries are still filed under " \
           "'#{UNRELEASED}'. Attribute them to the versions that shipped them, newest first, " \
           "matching the '## vX.Y.Z (YYYY-MM-DD)' dialect this file already uses."
  end

  private

  def parsed_versions
    @parsed_versions ||= @headings.filter_map do |h|
      ver = version_of(h[:line])
      [h[:number], ver] if ver
    end
  end

  def version_of(line)
    match = VERSION_HEADING.match(line)
    match && match[1].split(".").map(&:to_i)
  end
end
