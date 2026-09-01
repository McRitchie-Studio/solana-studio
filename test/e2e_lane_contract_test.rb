require_relative "test_helper"
require "yaml"
require_relative "../bin/lib/e2e_executed_set"

# THE STATIC HALF of the browser lane's guard.
#
# bin/e2e-executed-set-check reads Playwright's receipt and answers "did the lane
# RUN what it claims?". That check only exists in CI, after a browser has run. This
# one runs in the ordinary suite, on every change, and answers the questions a
# source reader can answer: does the committed contract still describe the
# committed specs, can anything in the lane narrow the set, and do the lab pages
# still render the gem's real partials rather than copies of them.
#
# Together they close the gap that a green browser lane otherwise leaves open.
class E2eLaneContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CONTRACT = YAML.safe_load_file(File.join(ROOT, "config", "e2e_lane.yml")).freeze
  SPEC_GLOB = File.join(ROOT, "e2e", "*.spec.js").freeze

  def spec_files
    Dir[SPEC_GLOB].sort
  end

  # Playwright's own `test("…")` call sites. Deliberately NOT counting
  # `test.describe` / hooks — the contract counts SPECS.
  def spec_count(path)
    File.read(path).scan(/^\s*test\(\s*["'`]/).size
  end

  def test_there_are_specs_to_contract_about
    # Guards the guard: an empty glob makes every assertion below vacuous, which
    # is the failure this whole pair of files exists to prevent.
    refute_empty spec_files, "no e2e specs found — the contract would be checking nothing"
  end

  def test_every_spec_file_is_declared_in_the_contract
    declared = CONTRACT.fetch("files").keys.map { |f| File.basename(f) }.sort
    on_disk = spec_files.map { |f| File.basename(f) }.sort

    assert_equal on_disk, declared,
                 "config/e2e_lane.yml must name exactly the spec files that exist — a NEW spec file " \
                 "that nobody declared runs in the lane while the contract stays silent about it"
  end

  def test_the_declared_counts_match_the_committed_specs
    CONTRACT.fetch("files").each do |declared_file, declared_count|
      path = File.join(ROOT, declared_file)
      assert_path_exists path, "config/e2e_lane.yml names #{declared_file}, which does not exist"

      assert_equal declared_count, spec_count(path),
                   "#{declared_file} declares #{declared_count} spec(s) in config/e2e_lane.yml but " \
                   "contains #{spec_count(path)} — derive it with `npx playwright test --list`"
    end
  end

  def test_the_total_matches_the_sum_of_the_files
    assert_equal CONTRACT.fetch("files").values.sum, CONTRACT.fetch("total_specs"),
                 "total_specs must equal the per-file counts — two numbers that can disagree will"
  end

  # THE NARROWING SPELLINGS. Each of these silently shrinks the executed set while
  # every count above stays correct, which is exactly the shape the runtime gate
  # was built for — but catching them here costs a second instead of a browser run.
  def test_no_spec_can_narrow_the_executed_set
    offenders = spec_files.flat_map do |path|
      src = File.read(path)
      found = []
      found << "#{File.basename(path)}: test.only" if src.match?(/\btest\.only\b/)
      found << "#{File.basename(path)}: describe.only" if src.match?(/\bdescribe\.only\b/)
      found << "#{File.basename(path)}: test.skip" if src.match?(/\btest\.skip\b/)
      found << "#{File.basename(path)}: testInfo.skip" if src.match?(/testInfo\.skip/)
      found << "#{File.basename(path)}: test.fixme" if src.match?(/\btest\.fixme\b/)
      found
    end

    assert_empty offenders,
                 "these narrow the set while leaving every count correct: #{offenders.join(', ')}"
  end

  def test_the_playwright_config_does_not_grep_or_narrow
    config = File.read(File.join(ROOT, "playwright.config.js"))

    refute_match(/^\s*grep\b/, config, "a grep in the config silently shrinks the lane")
    refute_match(/onlyChanged|only-changed/, config, "--only-changed makes the executed set depend on the diff")
    refute_match(/^\s*retries:\s*[1-9]/, config, "a retry hides the intermittency this lane exists to surface")

    # THE AXES THAT SURVIVE EVERY COUNT ABOVE. grepInvert, testIgnore, testMatch
    # and shard each remove specs from the RUN while leaving the committed tree —
    # which is what every other assertion in this file reads — perfectly intact.
    # The glob e2e/*.spec.js is this lane's ONE declaration of its set; a second
    # place to declare it is a second place for the two to disagree.
    refute_match(/grepInvert|grep-invert/, config, "grepInvert removes specs every count here still declares")
    refute_match(/^\s*testIgnore\b/, config, "testIgnore drops a file the committed tree still contains")
    refute_match(/^\s*testMatch\b/, config, "testMatch re-declares the set; e2e/*.spec.js already does")
    refute_match(/^\s*shard\b/, config, "a shard runs a FRACTION of the set and still reports green")
  end

  # THE LAB INVARIANT. A lab page may set up a partial's locals and nothing else.
  # The moment a page hand-rolls what the gem does, the specs grade the LAB and the
  # lane reports green over gem code no browser touched — and every spec still
  # passes, which is why this is asserted rather than trusted.
  def test_the_lab_pages_render_the_gems_real_partials_by_name
    modal_page = File.read(File.join(ROOT, "test/dummy/app/views/e2e_lab/modal.html.erb"))

    assert_match(/render\s+["']studio\/modals\/host["']/, modal_page,
                 "the modal page must render the ENGINE's real host, not a stand-in")
    assert_match(/render\s+["']solana_studio\/modals\/network_mismatch["']/, modal_page,
                 "the modal page must render the GEM's real partial by name")

    # The deep link's lab page. Its program is an INLINED base58 encoder on the
    # signing path, so a hand-rolled copy here would be the worst version of this
    # failure: the specs would decode a payload the gem never produced and report
    # green over a shipped encoder no browser touched.
    deeplink_page = File.read(File.join(ROOT, "test/dummy/app/views/e2e_lab/phantom_deeplink.html.erb"))

    assert_match(/render\s+["']solana_studio\/phantom_deeplink["']/, deeplink_page,
                 "the deep link page must render the GEM's real partial by name")
    refute_match(/startPhantomDeepLink\s*=/, deeplink_page,
                 "the lab page defines the entry point itself — the specs would then be grading the lab, " \
                 "and every one of them would still pass")
  end

  # BOTH STATES, on one page. The deep link's absence is half the property under
  # test: the picker gates its mobile Phantom row on the entry point existing, so a
  # spec can only observe that as a DIFFERENCE. A lab page that lost its conditional
  # would render the partial unconditionally, the negative spec would fail loudly —
  # but a page that lost the RENDER instead would leave the negative spec passing
  # while the positive one broke, which is why the render is asserted above too.
  def test_the_deep_link_lab_page_can_serve_both_states
    page = File.read(File.join(ROOT, "test/dummy/app/views/e2e_lab/phantom_deeplink.html.erb"))

    assert_match(/params\[:deeplink\]/, page,
                 "the deep link page must choose its state from the request, so one page serves both")
    assert_match(/data-deeplink=/, page,
                 "the page must publish which state it rendered — without it a spec cannot prove it " \
                 "loaded the page it meant to rather than asserting against some other document")
  end

  def test_the_lab_serves_the_shipped_javascript_not_a_copy
    layout = File.read(File.join(ROOT, "test/dummy/app/views/layouts/e2e_lab.html.erb"))
    boot = File.read(File.join(ROOT, "e2e/boot.rb"))

    assert_match(%r{/e2e/js/solana_studio/network_guard\.js}, layout,
                 "the lab must load the guard by path from public/e2e")
    assert_match(%r{app.{0,3}"assets".{0,3}"javascripts".{0,3}"solana_studio"}m, boot,
                 "e2e/boot.rb must COPY the gem's real app/assets JavaScript — a lab that served a " \
                 "re-typed copy would report green over a file nobody ships")
  end

  # The lab layout carries the ancestor Alpine scope the engine's modal host needs.
  # Without it the host's template is never processed and the modal never opens —
  # a failure that looks perfectly correct in the served HTML, and which cost a
  # debugging round the first time this lane was stood up.
  def test_the_lab_layout_supplies_the_alpine_root_the_host_requires
    layout = File.read(File.join(ROOT, "test/dummy/app/views/layouts/e2e_lab.html.erb"))

    assert_match(/<body[^>]*\sx-data\b/, layout,
                 "the modal host roots at a template x-if with no x-data of its own; Alpine only " \
                 "walks trees beneath an x-data root, so the HOST must supply one")
  end
end
