require_relative "test_helper"
require "open3"

# The conditional Rails half.
#
# The contract has two directions and they cannot both be observed in one
# process — `require` is idempotent, so whichever ran first would decide the
# answer for the other. Each direction gets its own subprocess with its own
# clean load path. (The absence case is also the state of THIS process, so it
# is asserted here directly as well.)
class EngineTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  # Runs `code` in a clean child and returns [stdout, ok, stderr].
  #
  # THE STREAMS STAY SEPARATE, and every assertion below reads STDOUT ALONE.
  # This helper used to fold them (`err: [:child, :out]`), and that made the
  # whole file unpassable under `bundle exec`: rubygems emits "already
  # initialized constant Gem::Platform::JAVA" warnings on the child's stderr,
  # they landed in `out`, and the exact-equality assertions compared them
  # against what the engine had printed. A bare `ruby -Itest` run emits no such
  # warnings and passed — so the desk and `bin/release-check` (which runs under
  # bundler) disagreed about the same tree, and a release stalled on it.
  #
  # The equality is the point — it proves the engine defines EXACTLY
  # `SolanaStudio::Engine` and nothing else, where a substring match would pass
  # on a subclass or a typo — so the CAPTURE is what had to change, not the
  # assertion. Stderr is still returned, deliberately, so a child that dies
  # reports why.
  def ruby(code)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I#{LIB}", "-e", code)
    [out.strip, status.success?, err.strip]
  end

  # THE REGRESSION, pinned at the level the defect lived: the helper, not the
  # cases that use it. Every other assertion in this file is an exact equality
  # against the child's stdout, so a helper that folds stderr in turns anything
  # the ENVIRONMENT says — bundler's rubygems warnings under `bin/release-check`
  # — into a diff against the engine's own output. That is not hypothetical:
  # it is what this test file did until now, and it read green at a desk while
  # failing the release gate on the identical tree.
  #
  # The child writes to BOTH streams on purpose. Restore `err: [:child, :out]`
  # and the stdout equality below fails on the leading "noise on stderr" line,
  # in every environment, with no bundler required to observe it.
  def test_the_subprocess_helper_keeps_stderr_out_of_stdout
    out, ok, err = ruby(<<~CODE)
      warn "noise on stderr"
      puts "SolanaStudio::Engine"
    CODE

    assert ok, "stream-separation probe failed: #{err}"

    # STDOUT is asserted EXACTLY: this test writes every byte of it.
    assert_equal ["SolanaStudio::Engine"], out.lines.map(&:strip),
                 "stdout must carry the child's stdout ALONE — a warning on stderr " \
                 "must never reach an assertion that reads stdout"

    # STDERR is asserted by PRESENCE, never equality — it is SHARED with the
    # runtime. A child inheriting a BUNDLE_GEMFILE from another gem (what
    # happens when bin/release-check is reached from the hub's already-bundled
    # release sweep) reloads rubygems_ext over an initialized rubygems and
    # prints 17 "already initialized constant Gem::Platform" lines here. An
    # equality would encode "the environment is quiet" — the same false
    # assumption, one stream over, that this file exists to remove.
    assert_includes err.lines.map(&:strip), "noise on stderr",
                    "stderr must still be captured and returned, so a child that dies says why"
  end

  def test_engine_is_absent_without_rails
    # The whole reason the engine lives behind a guard: chain-ops scripts and
    # bare rake tasks load this gem without railties installed. A hard require
    # would take them all down.
    out, ok, err = ruby(<<~CODE)
      require "solana_studio"
      puts defined?(SolanaStudio::Engine).inspect
      puts defined?(Rails).inspect
    CODE

    assert ok, "plain require failed: #{err}"
    assert_equal ["nil", "nil"], out.lines.map(&:strip)
  end

  def test_this_process_has_no_engine_either
    refute defined?(SolanaStudio::Engine), "engine leaked into the Rails-free suite"
  end

  def test_solana_primitives_load_without_rails
    # Guards the actual regression the conditional exists to prevent: adding a
    # Rails-dependent file must not break the Rails-free surface.
    out, ok, err = ruby(<<~CODE)
      require "solana_studio"
      kp = Solana::Keypair.generate
      puts kp.to_base58.length > 0
      puts Solana::Network.genesis_hash("devnet")
    CODE

    assert ok, "Rails-free primitives failed: #{err}"
    assert_equal ["true", "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"], out.lines.map(&:strip)
  end

  def test_engine_defines_when_rails_is_loaded
    out, ok, err = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      puts SolanaStudio::Engine.name
      puts SolanaStudio::Engine.ancestors.include?(::Rails::Engine)
    CODE

    assert ok, "engine failed to define under Rails: #{err}"
    assert_equal ["SolanaStudio::Engine", "true"], out.lines.map(&:strip)
  end

  def test_engine_serves_its_views_from_the_gem
    # An engine that defines but does not contribute its view path ships a modal
    # nobody can render. Assert the partial is reachable on the engine's paths,
    # not merely that the file exists on disk.
    out, ok, err = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      paths = SolanaStudio::Engine.paths["app/views"].existent
      puts paths.any? { |p| File.exist?(File.join(p, "solana_studio/modals/_network_mismatch.html.erb")) }
    CODE

    assert ok, "view path lookup failed: #{err}"
    assert_equal "true", out
  end

  def test_asset_initializer_is_registered
    out, ok, err = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      names = SolanaStudio::Engine.initializers.map(&:name).map(&:to_s)
      puts names.include?("solana_studio.assets")
    CODE

    assert ok, "initializer lookup failed: #{err}"
    assert_equal "true", out
  end
end
