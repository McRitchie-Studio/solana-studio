# frozen_string_literal: true

module Solana
  # Cluster identity — the one place that knows what "devnet" IS.
  #
  # A Solana cluster has three names that must agree, and nothing in the
  # protocol makes them agree for you:
  #
  #   1. The operator's name for it   — "devnet"          (SOLANA_NETWORK)
  #   2. The chain's own fingerprint  — genesis hash      (getGenesisHash)
  #   3. The wallet's name for it     — "solana:devnet"   (Wallet Standard)
  #
  # Every mis-alignment bug in this ecosystem is two of those three disagreeing:
  # a mainnet program ID against a devnet RPC (caught at boot by the host's
  # alignment check), or an app on devnet against a wallet on mainnet (caught at
  # sign-in, by handing the wallet name #3 and letting it object).
  #
  # This module is deliberately Rails-free and RPC-free — it is a lookup table
  # with opinions. Fetching the live genesis hash is the HOST's job — the RPC call
  # is `getGenesisHash`, which this gem's Solana::Client does not wrap today (turf
  # monster adds it in an initializer); deciding what to DO about a mismatch is the
  # host's too.
  module Network
    # Canonical cluster names, as Solana's own tooling spells them. Note
    # "mainnet-beta" — the hyphenated form is the real one; "mainnet" is an
    # alias people type, normalized by .canonical.
    MAINNET = "mainnet-beta"
    DEVNET  = "devnet"
    TESTNET = "testnet"
    LOCALNET = "localnet"

    CLUSTERS = [MAINNET, DEVNET, TESTNET, LOCALNET].freeze

    # The genesis block hash of each public cluster — a chain's immutable
    # fingerprint, and the only cluster identifier that cannot be misconfigured.
    # An RPC URL can lie (a proxy, a fork, a typo'd host); its genesis hash
    # cannot. localnet is absent on purpose: a fresh validator generates a new
    # genesis every time it boots, so there is no constant to pin.
    GENESIS_HASHES = {
      MAINNET => "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d",
      DEVNET  => "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG",
      TESTNET => "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
    }.freeze

    # Wallet Standard chain identifiers (CAIP-2 namespace "solana"), the form a
    # browser wallet speaks. Phantom and every Wallet-Standard wallet advertise
    # these in `wallet.chains` and accept one as the SIWS `chainId`.
    #
    # Mind the asymmetry: the Wallet Standard spells mainnet "solana:mainnet",
    # WITHOUT the -beta suffix the operator name carries. Passing
    # "solana:mainnet-beta" is not a near-miss the wallet forgives — it is an
    # unrecognized chain.
    WALLET_STANDARD_CHAINS = {
      MAINNET  => "solana:mainnet",
      DEVNET   => "solana:devnet",
      TESTNET  => "solana:testnet",
      # localnet is a valid Wallet Standard chain, but NOT a valid SIWS chainId —
      # no wallet can verify a sign-in against a chain only your machine has. It is
      # here for completeness of the chain table; do not send it as a chainId.
      LOCALNET => "solana:localnet"
    }.freeze

    # Human labels for UI. Anything unrecognized is deliberately NOT given a
    # friendly name — an unknown cluster is a fact worth showing the operator,
    # not something to paper over.
    LABELS = {
      MAINNET  => "Mainnet",
      DEVNET   => "Devnet",
      TESTNET  => "Testnet",
      LOCALNET => "Localnet"
    }.freeze

    ALIASES = {
      "mainnet"      => MAINNET,
      "mainnet-beta" => MAINNET,
      "main"         => MAINNET,
      "dev"          => DEVNET,
      "local"        => LOCALNET,
      "localhost"    => LOCALNET
    }.freeze

    module_function

    # Normalize an operator-supplied cluster name to its canonical spelling.
    # Returns nil for anything unrecognized — callers decide whether an unknown
    # cluster is a warning or a refusal, and they need to be able to tell.
    def canonical(cluster)
      return nil if cluster.nil?

      name = cluster.to_s.strip.downcase
      return nil if name.empty?
      return name if CLUSTERS.include?(name)

      ALIASES[name]
    end

    def known?(cluster)
      !canonical(cluster).nil?
    end

    # The pinned genesis hash for a cluster, or nil when there isn't one
    # (unknown cluster, or localnet — whose genesis is per-boot).
    def genesis_hash(cluster)
      GENESIS_HASHES[canonical(cluster)]
    end

    # Reverse lookup: given a hash from getGenesisHash, which cluster is this?
    # This is how you learn what an RPC URL ACTUALLY points at, as opposed to
    # what its hostname claims. nil means "no public cluster we know" — which
    # for a localnet validator is the correct and expected answer.
    def cluster_for_genesis(hash)
      return nil if hash.nil? || hash.to_s.strip.empty?

      GENESIS_HASHES.key(hash.to_s.strip)
    end

    # The Wallet Standard chain id for a cluster — the value to hand a browser
    # wallet as the SIWS `chainId` so the wallet compares it against its OWN
    # selected network and objects when they differ.
    #
    # This is the ONLY pre-emptive mismatch signal available to a website:
    # wallets do not expose their selected cluster for reading. You cannot ask;
    # you can only assert and let the wallet contradict you.
    def wallet_standard_chain(cluster)
      WALLET_STANDARD_CHAINS[canonical(cluster)]
    end

    def label(cluster)
      LABELS[canonical(cluster)] || "Unknown Network"
    end

    # The cluster an environment is SUPPOSED to run against. Production means
    # real money, so it means mainnet; everything else means devnet. A host that
    # disagrees (a mainnet-facing staging rehearsal, say) passes its own map.
    def expected_for_environment(environment)
      environment.to_s == "production" ? MAINNET : DEVNET
    end

    # Does a live genesis hash confirm the declared cluster?
    #
    # Three outcomes, and the middle one matters: :aligned (the chain is who it
    # says), :mismatched (it is a DIFFERENT known chain — the dangerous case),
    # and :unverifiable (no pinned hash to compare, i.e. localnet or an unknown
    # cluster name). Callers must not collapse :unverifiable into either of the
    # other two — refusing to boot on localnet is as wrong as trusting a
    # mainnet RPC that answered with a devnet genesis.
    #
    # THERE IS DELIBERATELY NO `aligned?` BOOLEAN. One existed and was removed in
    # review: it answered `false` for :unverifiable, so a host writing the obvious
    # `raise unless aligned?` would refuse to boot against a local validator —
    # precisely the mistake the paragraph above warns about, re-introduced by the
    # convenience wrapper meant to save callers from it. Three states, three
    # branches; the caller decides what :unverifiable means for them.
    def alignment(cluster:, genesis_hash:)
      expected = self.genesis_hash(cluster)
      return :unverifiable if expected.nil?
      return :unverifiable if genesis_hash.nil? || genesis_hash.to_s.strip.empty?

      genesis_hash.to_s.strip == expected ? :aligned : :mismatched
    end

    # Everything a UI needs to explain a network to a person, in one hash.
    # Serialized straight into a data attribute by the host so the browser guard
    # reads the same facts the server holds.
    def describe(cluster, environment: nil)
      canonical_name = canonical(cluster)
      {
        cluster: canonical_name,
        declared: cluster.to_s,
        known: !canonical_name.nil?,
        label: label(cluster),
        genesis_hash: genesis_hash(cluster),
        wallet_standard_chain: wallet_standard_chain(cluster),
        environment: environment&.to_s,
        expected_cluster: environment.nil? ? nil : expected_for_environment(environment)
      }
    end
  end
end
