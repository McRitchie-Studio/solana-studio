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
    assert_includes spec.files, "app/assets/javascripts/solana_studio/network_guard.js"
  end

  def test_manifest_carries_no_directory_entries
    dirs = Dir.chdir(ROOT) { spec.files.select { |f| File.directory?(f) } }
    assert_empty dirs, "spec.files must list files, not directories"
  end

  def test_version_matches_the_library_constant
    # A gemspec version that outruns SolanaStudio::VERSION publishes a gem whose
    # own constant lies about which version it is.
    assert_equal SolanaStudio::VERSION, spec.version.to_s
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
