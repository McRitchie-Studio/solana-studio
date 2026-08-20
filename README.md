# SolanaStudio

Ruby primitives for building on Solana — JSON-RPC client, Ed25519 keypairs, Borsh serialization, and transaction builder with PDA derivation.

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

## Installation

```ruby
# Gemfile
gem "solana-studio", "~> 0.5.0"
```

Consumer apps use the RubyGems release. Use a local path only while actively developing the gem, and restore the RubyGems dependency before merging.

## Usage

### Keypair

```ruby
require "solana-studio"

# Generate a new keypair
kp = Solana::Keypair.generate
kp.address          # => "9Fy8P3DvKBh3awt1wr27g4CDh47oDqmJR2FAAQ1bc69D"
kp.to_bytes         # => 64-byte Solana format

# Load from file or env
kp = Solana::Keypair.from_json_file("~/.config/solana/id.json")
kp = Solana::Keypair.from_base58(ENV["SOLANA_ADMIN_KEY"])

# Sign a message
signature = kp.sign("hello".b)
```

### Client (JSON-RPC)

```ruby
client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")

client.get_balance("9Fy8P3DvKBh3awt...")
client.get_latest_blockhash
client.request_airdrop("9Fy8P3DvKBh3awt...", 1_000_000_000)
client.send_and_confirm(signed_tx_base64)
```

### Borsh Serialization

```ruby
data = Solana::Borsh.encode_u64(1_000_000) +
       Solana::Borsh.encode_string("hello") +
       Solana::Borsh.encode_pubkey(kp.public_key_bytes)
```

### Transaction Builder

```ruby
tx = Solana::Transaction.new
tx.set_recent_blockhash(client.get_latest_blockhash)
tx.add_signer(keypair)
tx.add_instruction(
  program_id: "YourProgramId...",
  accounts: [
    { pubkey: keypair.public_key_bytes, is_signer: true, is_writable: true },
    { pubkey: pda, is_signer: false, is_writable: true }
  ],
  data: Solana::Transaction.anchor_discriminator("your_instruction") + payload
)

signature = client.send_and_confirm(tx.serialize_base64)
```

### PDA Derivation

```ruby
pda, bump = Solana::Transaction.find_pda(
  ["vault".b, wallet_pubkey_bytes],
  program_id_bytes
)
```

### Network (cluster identity)

A Solana cluster has three names that must agree, and nothing in the protocol
makes them agree for you: the operator's name (`devnet`), the chain's own
fingerprint (its genesis hash), and the wallet's name (`solana:devnet`).
`Solana::Network` is the lookup table that relates them.

```ruby
Solana::Network.genesis_hash("devnet")          # => "EtWTRABZaYq6..."
Solana::Network.cluster_for_genesis(hash)       # => "mainnet-beta" (what an RPC ACTUALLY is)
Solana::Network.wallet_standard_chain("mainnet-beta")  # => "solana:mainnet"  (note: no -beta)
Solana::Network.canonical("mainnet")            # => "mainnet-beta"; nil if unrecognized
Solana::Network.expected_for_environment("qa")  # => "devnet"
```

Alignment has **three** outcomes, and collapsing the middle one is a bug:

```ruby
Solana::Network.alignment(cluster: "devnet", genesis_hash: live_hash)
# => :aligned | :mismatched | :unverifiable
```

`:unverifiable` means there was no pinned hash to compare — localnet (whose
genesis is minted per boot) or an unrecognized cluster name. Treating it as
`:mismatched` refuses to boot every local validator; treating it as `:aligned`
trusts a chain nobody checked.

## Rails engine (optional)

The gem is Rails-free by default — `railties` is **not** a runtime dependency,
and plain-Ruby consumers (scripts, rake tasks, `chain-ops`) never load a line of
it. When the gem is required inside a Rails process, `SolanaStudio::Engine`
defines itself and contributes the onchain UI primitives.

### Network mismatch guard

The problem: a user whose wallet is set to Mainnet, using a QA app that runs on
Devnet. Their wallet simulates against the wrong chain, shows a frightening
approval sheet and a balance from a chain nobody is using, and they abandon the
flow.

**A website cannot detect this directly.** Phantom does not expose its selected
network, and the Wallet Standard `chains` array lists what a wallet *supports*,
not what it has *selected*. There is no pre-flight read to write. So the guard
does the only two things that work:

**1. Assert at sign-in.** Hand the wallet a SIWS `chainId` and let it contradict
you — the one pre-emptive signal that exists.

```js
var signInInput = SolanaStudio.network.withSignInChainId({
  domain: window.location.host,
  nonce: nonce
});
// => adds chainId: "solana:devnet"
```

**2. Explain after a failure.** Wrap any onchain action. The guard never blocks
and never swallows an error — it re-throws the original rejection untouched, and
hands you a hint only when a mismatch would actually explain the failure.

```js
SolanaStudio.network.guard(
  function() { return provider.signTransaction(tx); },
  {
    action: "Entering this contest",
    onHint: function(hint) { Alpine.store('modals').open('network-mismatch', hint); }
  }
).then(broadcast);   // your existing .catch still receives the real error
```

`classify(err)` returns `"likely"`, `"possible"`, or `"unrelated"`, and is
calibrated to **under-claim**: an insufficient-funds error stays an
insufficient-funds error. Dressing up an unrelated failure as a network problem
sends the user to fix the wrong thing, which is the bug this feature exists to
remove.

### Host setup

```erb
<%# once, inside your modal host %>
<template x-if="$store.modals.current().id === 'network-mismatch'">
  <%= render "solana_studio/modals/network_mismatch" %>
</template>
```

```erb
<%# so the browser can read what the server knows %>
<body data-solana-network="<%= Solana::Network.describe(
        Solana::Config::NETWORK, environment: Rails.env).to_json %>">
```

The guard falls back to discrete `data-solana-cluster` / `data-app-environment`
attributes, so a host can adopt it before changing its layout.

Requires studio-engine's modal host (`Alpine.store('modals')`) and its shared
modal blocks. The JS is `solana_studio/network_guard.js` on the asset path.

## Dependencies

- `ed25519` (~> 1.3) — Ed25519 signing
- Ruby stdlib only (net/http, json, digest, securerandom)
- **No Rails dependency.** `railties` is a development dependency only; the
  engine loads solely when the host has already loaded Rails.

## Development Notes

See [RUNBOOK.md](./RUNBOOK.md) for troubleshooting and local test commands.

Run the suite with `bin/release-check` — the same entry point CI and the release
gate use, so they cannot drift apart. It enumerates test files by glob (no list
to forget a file from) and **fails a file that runs zero tests or skips one**,
because a suite that quietly stops covering something is the failure a green
build cannot show you. `node` is required: the browser guard's suite runs the
shipped `.js` under node with `window`/`document` stubs.

## License

MIT
