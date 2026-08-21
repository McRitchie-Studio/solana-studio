require_relative "test_helper"

# Cluster identity. The genesis hashes are pinned constants a mis-edit would
# silently invert (devnet's hash under the mainnet key boots a mainnet app
# against devnet and calls it aligned), so each is asserted literally rather
# than round-tripped through the table that defines it.
class NetworkTest < Minitest::Test
  N = Solana::Network

  MAINNET_GENESIS = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d".freeze
  DEVNET_GENESIS  = "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG".freeze
  TESTNET_GENESIS = "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY".freeze

  def test_genesis_hashes_are_the_canonical_cluster_fingerprints
    assert_equal MAINNET_GENESIS, N.genesis_hash("mainnet-beta")
    assert_equal DEVNET_GENESIS,  N.genesis_hash("devnet")
    assert_equal TESTNET_GENESIS, N.genesis_hash("testnet")
  end

  def test_localnet_has_no_pinned_genesis
    # A fresh validator mints a new genesis every boot — pinning one would be a
    # lie that fails every local run.
    assert_nil N.genesis_hash("localnet")
  end

  def test_canonical_normalizes_the_mainnet_aliases
    assert_equal "mainnet-beta", N.canonical("mainnet")
    assert_equal "mainnet-beta", N.canonical("mainnet-beta")
    assert_equal "mainnet-beta", N.canonical("MAINNET")
    assert_equal "mainnet-beta", N.canonical("  mainnet  ")
  end

  def test_canonical_returns_nil_for_unknown_so_callers_can_tell
    # nil, not a default — an unrecognized cluster name is a fact the caller
    # has to be able to see. Defaulting it to devnet is how a typo'd
    # SOLANA_NETWORK boots quietly.
    assert_nil N.canonical("mainnnet")
    assert_nil N.canonical("")
    assert_nil N.canonical(nil)
    refute N.known?("mainnnet")
  end

  def test_cluster_for_genesis_identifies_a_chain_by_its_fingerprint
    assert_equal "mainnet-beta", N.cluster_for_genesis(MAINNET_GENESIS)
    assert_equal "devnet",       N.cluster_for_genesis(DEVNET_GENESIS)
    assert_nil N.cluster_for_genesis("notAGenesisHash")
    assert_nil N.cluster_for_genesis(nil)
  end

  def test_wallet_standard_chain_drops_the_beta_suffix_for_mainnet
    # The asymmetry is the whole point of the lookup: the operator name is
    # "mainnet-beta", the Wallet Standard name is "solana:mainnet". Emitting
    # "solana:mainnet-beta" hands the wallet an unrecognized chain.
    assert_equal "solana:mainnet",  N.wallet_standard_chain("mainnet-beta")
    assert_equal "solana:devnet",   N.wallet_standard_chain("devnet")
    assert_equal "solana:testnet",  N.wallet_standard_chain("testnet")
    assert_equal "solana:localnet", N.wallet_standard_chain("localnet")
    assert_nil N.wallet_standard_chain("nonsense")
  end

  def test_alignment_confirms_a_matching_genesis
    assert_equal :aligned, N.alignment(cluster: "devnet", genesis_hash: DEVNET_GENESIS)
    assert_equal :aligned, N.alignment(cluster: "mainnet-beta", genesis_hash: MAINNET_GENESIS)
  end

  def test_alignment_flags_a_different_known_chain
    # The dangerous case: SOLANA_NETWORK says mainnet, the RPC answered with
    # devnet's genesis. This must be distinguishable from "cannot check".
    assert_equal :mismatched, N.alignment(cluster: "mainnet-beta", genesis_hash: DEVNET_GENESIS)
  end

  def test_alignment_is_unverifiable_rather_than_mismatched_without_a_pin
    # localnet and unknown clusters have no hash to compare. Collapsing this
    # into :mismatched refuses to boot every local validator; collapsing it into
    # :aligned trusts a chain nobody checked. It gets its own answer.
    assert_equal :unverifiable, N.alignment(cluster: "localnet", genesis_hash: "whateverThisBootMinted")
    assert_equal :unverifiable, N.alignment(cluster: "mainnnet", genesis_hash: MAINNET_GENESIS)
    assert_equal :unverifiable, N.alignment(cluster: "devnet", genesis_hash: nil)
    assert_equal :unverifiable, N.alignment(cluster: "devnet", genesis_hash: "  ")
  end

  def test_there_is_no_boolean_that_collapses_the_third_state
    # An `aligned?` convenience existed and was REMOVED in review. It answered
    # false for :unverifiable, so the obvious host spelling — `raise unless
    # aligned?` — would refuse to boot against a local validator, which is exactly
    # the mistake alignment's own doc-comment warns about. The wrapper meant to
    # save callers from the collapse WAS the collapse.
    #
    # Asserted so it cannot come back by convenience: three states, three branches.
    refute_respond_to N, :aligned?,
                      "a boolean cannot carry three states — callers must branch on alignment"
    assert_equal :unverifiable, N.alignment(cluster: "localnet", genesis_hash: "whateverThisBootMinted")
  end

  def test_expected_for_environment_maps_production_to_mainnet
    assert_equal "mainnet-beta", N.expected_for_environment("production")
    assert_equal "devnet", N.expected_for_environment("qa")
    assert_equal "devnet", N.expected_for_environment("development")
    assert_equal "devnet", N.expected_for_environment(:test)
  end

  def test_describe_carries_every_name_a_ui_needs
    d = N.describe("mainnet", environment: "production")

    assert_equal "mainnet-beta", d[:cluster]
    assert_equal "mainnet", d[:declared]
    assert_equal true, d[:known]
    assert_equal "Mainnet", d[:label]
    assert_equal MAINNET_GENESIS, d[:genesis_hash]
    assert_equal "solana:mainnet", d[:wallet_standard_chain]
    assert_equal "production", d[:environment]
    assert_equal "mainnet-beta", d[:expected_cluster]
  end

  def test_describe_reports_an_unknown_cluster_as_unknown
    d = N.describe("mainnnet", environment: "qa")

    assert_nil d[:cluster]
    assert_equal "mainnnet", d[:declared]
    assert_equal false, d[:known]
    assert_equal "Unknown Network", d[:label]
    assert_nil d[:genesis_hash]
    assert_nil d[:wallet_standard_chain]
    assert_equal "devnet", d[:expected_cluster]
  end
end
