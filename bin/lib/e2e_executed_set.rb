# frozen_string_literal: true

# The arithmetic behind bin/e2e-executed-set-check, factored out so it is unit
# testable without running a browser.
#
# STDLIB ONLY (json + yaml), deliberately: this gate AUDITS the suite, so it must
# not be breakable by a dependency problem in the thing it audits. It needs no
# bundle and no node.
require "json"
require "yaml"

module E2eExecutedSet
  Result = Struct.new(:ok, :failures, :summary, keyword_init: true)

  module_function

  # Every spec in the report, flattened out of Playwright's nested suites.
  def specs(report)
    out = []
    walk = lambda do |suite, file|
      here = suite["file"] || file
      Array(suite["specs"]).each { |s| out << { "file" => here, "title" => s["title"], "ok" => s["ok"] } }
      Array(suite["suites"]).each { |child| walk.call(child, here) }
    end
    Array(report["suites"]).each { |s| walk.call(s, s["file"]) }
    out
  end

  def check(report, contract)
    stats = report["stats"] || {}
    expected = stats["expected"].to_i
    skipped = stats["skipped"].to_i
    unexpected = stats["unexpected"].to_i
    total = contract["total_specs"].to_i
    failures = []

    # A --list run produces a receipt where EVERY spec is skipped and none ran.
    # Reading that as "the whole lane failed" would be technically true and
    # useless; refusing it names the actual mistake.
    if expected.zero? && skipped.positive? && unexpected.zero?
      failures << "the report shows #{skipped} skipped and NOTHING executed — this looks like a " \
                  "`--list` receipt rather than a run. Point the gate at a real `npx playwright test`."
      return Result.new(ok: false, failures: failures, summary: "expected=0 skipped=#{skipped}")
    end

    failures << "#{skipped} spec(s) SKIPPED — a skip is coverage the green lane no longer has" if skipped.positive?
    failures << "#{unexpected} spec(s) failed" if unexpected.positive?

    if expected != total
      failures << "executed #{expected} spec(s), contract declares #{total}. Either a spec left the " \
                  "executed set, or config/e2e_lane.yml is stale — derive it with `npx playwright test --list`."
    end

    # Per-FILE counts, so moving a spec between files (which keeps the total
    # right) still has to be declared.
    by_file = specs(report).group_by { |s| s["file"] }.transform_values(&:size)
    Array(contract["files"]).each do |declared_file, declared_count|
      key = by_file.keys.find { |f| f.to_s.end_with?(File.basename(declared_file.to_s)) }
      actual = key ? by_file[key] : 0
      next if actual == declared_count.to_i

      failures << "#{declared_file}: executed #{actual}, contract declares #{declared_count}"
    end

    Result.new(
      ok: failures.empty?,
      failures: failures,
      summary: "expected=#{expected} skipped=#{skipped} unexpected=#{unexpected} contract=#{total}"
    )
  end
end
