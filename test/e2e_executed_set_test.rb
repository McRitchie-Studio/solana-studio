require_relative "test_helper"
require_relative "../bin/lib/e2e_executed_set"

# The verdict gate's arithmetic, without a browser.
#
# bin/e2e-executed-set-check only runs in CI, after Playwright. Its logic is the
# thing standing between "the lane is green" and "the lane covered what it claims",
# so it gets tested at a tier that runs on every change — otherwise the guard
# itself is the least-exercised code in the repo.
class E2eExecutedSetTest < Minitest::Test
  CONTRACT = { "total_specs" => 7, "files" => { "e2e/a.spec.js" => 4, "e2e/b.spec.js" => 3 } }.freeze

  def report(expected:, skipped: 0, unexpected: 0, a: 4, b: 3)
    {
      "stats" => { "expected" => expected, "skipped" => skipped, "unexpected" => unexpected },
      "suites" => [
        { "file" => "e2e/a.spec.js", "specs" => Array.new(a) { |i| { "title" => "a#{i}", "ok" => true } } },
        { "file" => "e2e/b.spec.js", "specs" => Array.new(b) { |i| { "title" => "b#{i}", "ok" => true } } }
      ]
    }
  end

  def test_a_full_clean_run_passes
    result = E2eExecutedSet.check(report(expected: 7), CONTRACT)

    assert result.ok, result.failures.join(" | ")
  end

  # THE SPELLING THAT MOTIVATED THE GATE. testInfo.skip() exits 0 and leaves every
  # static count correct; only the receipt shows the spec left the executed set.
  def test_a_runtime_skip_fails_even_though_nothing_errored
    result = E2eExecutedSet.check(report(expected: 6, skipped: 1), CONTRACT)

    refute result.ok
    assert_includes result.failures.join(" "), "SKIPPED"
  end

  def test_a_failed_spec_fails
    refute E2eExecutedSet.check(report(expected: 6, unexpected: 1), CONTRACT).ok
  end

  # A --grep or --only-changed shrinks the run without skipping anything: fewer
  # specs simply never appear. The total is what catches it.
  def test_a_narrowed_run_fails_on_the_total
    result = E2eExecutedSet.check(report(expected: 4, a: 4, b: 0), CONTRACT)

    refute result.ok
    assert_includes result.failures.join(" "), "contract declares 7"
  end

  # Moving a spec between files keeps the TOTAL right, so the per-file counts are
  # what make that visible.
  def test_moving_a_spec_between_files_fails_the_per_file_count
    result = E2eExecutedSet.check(report(expected: 7, a: 5, b: 2), CONTRACT)

    refute result.ok
    assert_includes result.failures.join(" "), "e2e/a.spec.js"
  end

  # A `--list` receipt reports every spec skipped and none executed. Reading that
  # as a catastrophic failure would be true and useless; naming it points at the
  # actual mistake.
  def test_a_list_receipt_is_refused_by_name
    result = E2eExecutedSet.check(report(expected: 0, skipped: 7, a: 4, b: 3), CONTRACT)

    refute result.ok
    assert_includes result.failures.join(" "), "`--list`"
  end

  def test_specs_are_flattened_out_of_nested_suites
    nested = {
      "stats" => { "expected" => 1, "skipped" => 0, "unexpected" => 0 },
      "suites" => [{ "file" => "e2e/a.spec.js", "suites" => [{ "specs" => [{ "title" => "deep", "ok" => true }] }] }]
    }

    assert_equal [{ "file" => "e2e/a.spec.js", "title" => "deep", "ok" => true }], E2eExecutedSet.specs(nested)
  end
end
