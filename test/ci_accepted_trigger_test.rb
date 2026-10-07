# frozen_string_literal: true

# LINT: the suite workflow builds every push to `accepted` (and `release`, `main`).
#
# WHY. Review merges approved PRs onto `accepted`, and `bin/release prepare`
# promotes it only if its CI verdict is not red (refuse_red_accepted!). A repo
# whose suite workflow has no `accepted` push trigger produces no run there, so
# that guard reads no verdict and passes the rung uncertified. The hub's
# refuse_blind_accepted! catches it at promote time; this lint catches it at the
# edit that causes it, in this repo's own CI. Task: accepted-trigger-lint.
#
# The hub finds this repo's verdict by the workflow's `name:` ("Gem CI"), so the lint
# matches by name, not by file name.
#
# Run directly:
#   ruby -Itest test/ci_accepted_trigger_test.rb
require_relative "test_helper"
require "yaml"

class CiAcceptedTriggerTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SUITE_WORKFLOW = "Gem CI"
  WORKFLOW_DIR = File.join(ROOT, ".github/workflows")
  # The rungs the release ladder promotes through. `accepted` is the one this file
  # exists for; `release` and `main` ride along because the argument is the same.
  RUNGS = %w[accepted release main].freeze
  # A path filter suppresses the whole RUN, so a docs-only merge gets no verdict
  # while `branches:` still reads correct.
  PATH_FILTER_KEYS = %w[paths paths-ignore].freeze

  # Does this workflow build every push to `branch`? Mirrors the hub's
  # Release::AcceptedCertification.certifies?, which bin/release prepare reads.
  def self.builds_pushes_to?(yaml_text, branch)
    doc = YAML.safe_load(yaml_text.to_s, aliases: true)
    return false unless doc.is_a?(Hash)

    # YAML 1.1 reads a bare `on:` key as the boolean true.
    on = doc.key?(true) ? doc[true] : doc["on"]
    return Array(on).map(&:to_s).include?("push") if on.is_a?(Array) || on.is_a?(String)
    return false unless on.is_a?(Hash) && on.key?("push")

    push = on["push"]
    return true if push.nil? # `push:` with no filter builds every branch
    return false unless push.is_a?(Hash)
    return false if push.keys.intersect?(PATH_FILTER_KEYS)

    branches = push["branches"]
    return !Array(push["branches-ignore"]).map(&:to_s).include?(branch) if branches.nil?

    Array(branches).map(&:to_s).include?(branch)
  rescue Psych::SyntaxError
    false # an unreadable workflow certifies nothing
  end

  def self.name_of(yaml_text)
    doc = YAML.safe_load(yaml_text.to_s, aliases: true)
    doc.is_a?(Hash) ? doc["name"]&.to_s : nil
  end

  def suite_workflows
    paths = Dir[File.join(WORKFLOW_DIR, "*.{yml,yaml}")].sort
    refute_empty paths, "no workflows at #{WORKFLOW_DIR}: this lint is looking in the wrong place"
    paths.select { |path| self.class.name_of(File.read(path)) == SUITE_WORKFLOW }
  end

  # --- the lint, against this repo's own workflows ----------------------------------

  def test_exactly_one_workflow_carries_the_suite_name
    found = suite_workflows

    assert_equal 1, found.size,
                 "expected one workflow named #{SUITE_WORKFLOW.inspect}, found #{found.map { |p| File.basename(p) }.inspect}. " \
                 "The hub matches this repo's runs by that name; rename it and every verdict reads as missing."
  end

  def test_the_suite_workflow_builds_every_rung_of_the_ladder
    suite_workflows.each do |path|
      text = File.read(path)
      RUNGS.each do |rung|
        assert self.class.builds_pushes_to?(text, rung),
               "#{File.basename(path)} (#{SUITE_WORKFLOW.inspect}) does not build pushes to `#{rung}`. Give it " \
               "`push: branches: [main, release, accepted]` with no path filter or branches-ignore. Without it " \
               "the rung gets no CI run, so the hub's red-accepted guard reads no verdict and passes it uncertified."
      end
    end
  end

  # --- the predicate, against synthetic workflows -------------------------------------

  def workflow(on_block)
    "name: #{SUITE_WORKFLOW}\non:\n#{on_block}\njobs: {}\n"
  end

  def test_unit_a_workflow_with_no_accepted_trigger_fails
    refute self.class.builds_pushes_to?(workflow("  pull_request:\n  push:\n    branches: [main, release]"), "accepted")
  end

  def test_unit_a_workflow_with_an_accepted_trigger_passes
    assert self.class.builds_pushes_to?(workflow("  pull_request:\n  push:\n    branches: [main, release, accepted]"), "accepted")
  end

  def test_unit_a_pull_request_only_workflow_fails
    refute self.class.builds_pushes_to?(workflow("  pull_request:"), "accepted")
  end

  def test_unit_a_path_filter_fails_even_with_the_branch_listed
    refute self.class.builds_pushes_to?(
      workflow("  push:\n    branches: [accepted]\n    paths: ['lib/**']"), "accepted"
    )
  end

  def test_unit_branches_ignore_naming_accepted_fails
    refute self.class.builds_pushes_to?(workflow("  push:\n    branches-ignore: [accepted]"), "accepted")
    assert self.class.builds_pushes_to?(workflow("  push:\n    branches-ignore: [gh-pages]"), "accepted")
  end

  def test_unit_unfiltered_push_spellings_pass
    assert self.class.builds_pushes_to?(workflow("  push:"), "accepted")
    assert self.class.builds_pushes_to?("name: x\non: push\njobs: {}\n", "accepted")
    assert self.class.builds_pushes_to?("name: x\non: [push, pull_request]\njobs: {}\n", "accepted")
  end

  def test_unit_unparseable_yaml_fails
    refute self.class.builds_pushes_to?("on: [unclosed", "accepted")
  end
end
