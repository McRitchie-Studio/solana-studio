require_relative "test_helper"

# The conditional Rails half.
#
# The contract has two directions and they cannot both be observed in one
# process — `require` is idempotent, so whichever ran first would decide the
# answer for the other. Each direction gets its own subprocess with its own
# clean load path. (The absence case is also the state of THIS process, so it
# is asserted here directly as well.)
class EngineTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def ruby(code)
    out = IO.popen([RbConfig.ruby, "-I#{LIB}", "-e", code], err: [:child, :out], &:read)
    [out.strip, $?.success?]
  end

  def test_engine_is_absent_without_rails
    # The whole reason the engine lives behind a guard: chain-ops scripts and
    # bare rake tasks load this gem without railties installed. A hard require
    # would take them all down.
    out, ok = ruby(<<~CODE)
      require "solana_studio"
      puts defined?(SolanaStudio::Engine).inspect
      puts defined?(Rails).inspect
    CODE

    assert ok, "plain require failed: #{out}"
    assert_equal ["nil", "nil"], out.lines.map(&:strip)
  end

  def test_this_process_has_no_engine_either
    refute defined?(SolanaStudio::Engine), "engine leaked into the Rails-free suite"
  end

  def test_solana_primitives_load_without_rails
    # Guards the actual regression the conditional exists to prevent: adding a
    # Rails-dependent file must not break the Rails-free surface.
    out, ok = ruby(<<~CODE)
      require "solana_studio"
      kp = Solana::Keypair.generate
      puts kp.to_base58.length > 0
      puts Solana::Network.genesis_hash("devnet")
    CODE

    assert ok, "Rails-free primitives failed: #{out}"
    assert_equal ["true", "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"], out.lines.map(&:strip)
  end

  def test_engine_defines_when_rails_is_loaded
    out, ok = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      puts SolanaStudio::Engine.name
      puts SolanaStudio::Engine.ancestors.include?(::Rails::Engine)
    CODE

    assert ok, "engine failed to define under Rails: #{out}"
    assert_equal ["SolanaStudio::Engine", "true"], out.lines.map(&:strip)
  end

  def test_engine_serves_its_views_from_the_gem
    # An engine that defines but does not contribute its view path ships a modal
    # nobody can render. Assert the partial is reachable on the engine's paths,
    # not merely that the file exists on disk.
    out, ok = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      paths = SolanaStudio::Engine.paths["app/views"].existent
      puts paths.any? { |p| File.exist?(File.join(p, "solana_studio/modals/_network_mismatch.html.erb")) }
    CODE

    assert ok, "view path lookup failed: #{out}"
    assert_equal "true", out
  end

  def test_asset_initializer_is_registered
    out, ok = ruby(<<~CODE)
      require "rails"
      require "solana_studio"
      names = SolanaStudio::Engine.initializers.map(&:name).map(&:to_s)
      puts names.include?("solana_studio.assets")
    CODE

    assert ok, "initializer lookup failed: #{out}"
    assert_equal "true", out
  end
end
