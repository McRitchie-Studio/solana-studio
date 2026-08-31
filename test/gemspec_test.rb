require_relative "test_helper"
require "rubygems"

# The packaging contract.
#
# This gem publishes through a release sweep that builds on release MEMBERSHIP,
# not on content — nothing downstream opens the .gem and checks what is inside.
# So a view added outside spec.files is invisible: the suite is green, CI is
# green, the sweep publishes, and the consumer app raises "missing partial" at
# runtime against a version that every gate signed off on.
#
# The assertion is therefore the INVARIANT (every shipped tree file is in the
# manifest) rather than a checklist of today's filenames — a checklist passes
# forever while the next new file silently escapes.
class GemspecTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def spec
    @spec ||= Dir.chdir(ROOT) { Gem::Specification.load("solana-studio.gemspec") }
  end

  # Directories whose entire contents must reach the published gem.
  SHIPPED_TREES = ["app", "lib"].freeze

  def test_every_file_in_a_shipped_tree_is_in_the_manifest
    missing = []

    Dir.chdir(ROOT) do
      SHIPPED_TREES.each do |tree|
        Dir.glob("#{tree}/**/*").each do |path|
          next if File.directory?(path)
          # lib ships .rb only — a stray fixture there is deliberately excluded.
          next if tree == "lib" && File.extname(path) != ".rb"

          missing << path unless spec.files.include?(path)
        end
      end
    end

    assert_empty missing, <<~MSG
      These files exist in the tree but would NOT be in the published gem:

        #{missing.join("\n  ")}

      Widen spec.files in solana-studio.gemspec. A consumer renders a partial
      that isn't there, and no gate before that point can see it.
    MSG
  end

  def test_the_engines_own_files_are_packaged
    # Belt-and-braces on the two that matter most: the modal a host renders and
    # the guard it loads. Named explicitly so a failure reads as "the engine is
    # not in the gem" rather than a generic count mismatch.
    assert_includes spec.files, "app/views/solana_studio/modals/_network_mismatch.html.erb"
    assert_includes spec.files, "app/views/solana_studio/auth/_wallet_credential.html.erb"
    assert_includes spec.files, "app/assets/javascripts/solana_studio/network_guard.js"
  end

  def test_manifest_carries_no_directory_entries
    dirs = Dir.chdir(ROOT) { spec.files.select { |f| File.directory?(f) } }
    assert_empty dirs, "spec.files must list files, not directories"
  end

  def test_the_version_file_declares_exactly_one_literal
    # config/release_repos.yml registers lib/solana_studio/version.rb as this
    # gem's version_file, and the conductor rewrites it with
    # Release::GemVersion.rewrite_version — which REFUSES a file declaring more
    # than one literal rather than guess which is real. A second one (a
    # commented-out old line, a MINIMUM_VERSION) strands the release with a
    # fix-this-by-hand instruction.
    # THE CONDUCTOR'S OWN REGEX, not a proxy for it. This asserted
    # /^\s*VERSION\s*=/ — anchored and uppercase-only — while
    # Release::GemVersion::VERSION_LITERAL is case-INSENSITIVE and UNANCHORED and
    # counts every match in the file. A comment in this file carrying a quoted
    # `version = "…"` would leave the old assertion green while the conductor
    # counted two and refused to rewrite, stranding the release. Copied because a
    # gem cannot depend on the hub; keep it in sync with
    # mcritchie-studio/app/models/release/gem_version.rb.
    conductor_regex = /version\s*=\s*["']([\w.\-]+)["']/i
    literals = File.read(File.join(ROOT, "lib/solana_studio/version.rb")).scan(conductor_regex)

    assert_equal 1, literals.length,
                 "the version file must declare exactly one literal for the release conductor to rewrite"
  end

  def test_the_gemspec_holds_no_version_literal_of_its_own
    # The reason the split exists. bin/dor-check refuses a PR that edits the
    # registered version_file, matching on PATH — so while the gemspec WAS the
    # version file, no PR could touch spec.files, the dependencies or the
    # metadata either, none of which the conductor writes and none of which had
    # another writer. A literal creeping back here would re-lock the manifest
    # AND give the conductor two files claiming the version.
    gemspec_src = File.read(File.join(ROOT, "solana-studio.gemspec"))

    refute_match(/spec\.version\s*=\s*["']/, gemspec_src,
                 "the gemspec must READ the version, never declare it")
    assert_match(/spec\.version\s*=\s*SolanaStudio::VERSION/, gemspec_src)
  end

  def test_the_gemspec_and_the_constant_cannot_disagree
    # Now that there is ONE source, this is a real invariant rather than the
    # trap it would have been while they were two independent literals.
    assert_equal SolanaStudio::VERSION, spec.version.to_s
  end

  def test_the_version_file_is_packaged
    # It is required by lib/solana_studio.rb at load time. Outside the manifest,
    # every consumer raises LoadError on require.
    assert_includes spec.files, "lib/solana_studio/version.rb"
  end

  def test_gem_declares_no_rails_runtime_dependency
    # The Rails-free contract, asserted rather than trusted: railties is a
    # DEVELOPMENT dependency only. If it ever becomes a runtime dependency,
    # every plain-Ruby consumer starts installing Rails.
    runtime = spec.runtime_dependencies.map(&:name)
    refute_includes runtime, "railties"
    refute_includes runtime, "rails"
    assert_equal ["ed25519"], runtime
  end
end
