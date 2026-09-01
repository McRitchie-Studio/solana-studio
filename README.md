# SolanaStudio

Ruby primitives for building on Solana — JSON-RPC client, Ed25519 keypairs, Borsh serialization, and transaction builder with PDA derivation.

> **Part of the McRitchie ecosystem** — see [`ECOSYSTEM.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/ECOSYSTEM.md) for the 5-repo map; [`house-burn-down.md`](https://github.com/amcritchie/mcritchie-studio/blob/main/docs/agents/system/house-burn-down.md) for fresh-Mac recovery.

## Installation

```ruby
# Gemfile
gem "solana-studio", "~> 0.5"
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

### Wallet sign-in button (the credential slot)

studio-engine owns the sign-in modal, because every app in the ecosystem signs
people in and most of them are web2. This gem owns the **wallet button** inside
it, because only a web3 app has wallets.

There is **nothing to wire up.** The engine's auth modal looks for a partial at
one fixed path and renders whatever it finds:

    solana_studio/auth/_wallet_credential

Bundling this gem puts that partial on the host's view path, so the button
appears. An app that does not bundle it finds nothing and renders nothing — no
wallet markup ships to a newsletter app, and no `render` call has to be deleted
to keep it out.

The engine asks two questions and needs both answered yes:

| Question | Answered by | Where |
|---|---|---|
| Does this app *want* wallet sign-in? | `Studio.auth_method?(:wallet)` and `Studio.feature?(:web3)` | the host's `config/initializers/studio.rb` |
| Is there a layer that *implements* it? | this partial resolving on the view path | bundling this gem |

Both matter. McRitchie Studio bundles this gem for the Ruby signing primitives
while shipping web3 **off**, so the partial is present and the button is
correctly absent. And an app that declares `:wallet` but forgets the gem gets no
button rather than a missing-partial error in front of someone signing in.

The partial renders inside the modal's own Alpine scope and borrows three
members from it — `methodOn('wallet')` for visibility, `attested()` for the
legal-age gate, and `props.submitting` for the disabled state. It takes one
required local, `modal_store`, which the engine passes.

Why a contributed button and not a second auth modal: Turf Monster wants Google
plus magic-link plus wallet, McRitchie Studio wants Google plus magic-link. A
forked modal would put a surface both apps sign in through into two files, which
is how the wallet picker reached three copies before it was promoted.
### Web3 modals

Four partials promoted out of studio-engine, where every consumer paid for them
whether or not it shipped a chain feature at all:

| Virtual path | What it is |
|---|---|
| `solana_studio/modals/wallet_connect` | The Connect-Wallet picker — detected wallets, install rows, and Phantom's mobile deep-link row |
| `solana_studio/modals/web3_step_up` | The sign-with-your-wallet step-up card |
| `solana_studio/phantom_deeplink` | Defines `window.startPhantomDeepLink(linkMode, currentUserId)` — the phone round trip |
| `solana_studio/deeplink_assets` | An idempotent, non-blocking tweetnacl loader for that round trip |

```erb
<%# once, inside your modal host %>
<template x-if="$store.modals.current().id === 'wallet-connect'">
  <%= render "solana_studio/modals/wallet_connect" %>
</template>

<template x-if="$store.modals.current().id === 'web3-step-up'">
  <%= render "solana_studio/modals/web3_step_up" %>
</template>
```

Render `solana_studio/phantom_deeplink` **once**, anywhere the Connect-Wallet
flow can be reached. The picker gates its mobile Phantom row on
`startPhantomDeepLink` existing, so a host that skips it keeps the install row
instead of painting a button that does nothing.

**These require studio-engine at render time.** They render its modal host and
its shared blocks (`studio/modals/blocks/wallet_brand_sprite`, `.../card_header`)
by name, paint with its utilities (`badge`, `pulse-cta`, `spinner`) and theme
role tokens, and drive its store through `$store.<store>.swap()`. studio-engine
stays a **development** dependency here — a runtime one would drag Rails into
every plain-Ruby consumer, which is what `lib/solana_studio/engine.rb`'s guard
exists to prevent — so this is a documented host requirement, not something the
gem can enforce from inside. `solana_studio/modals/network_mismatch` already
shipped on exactly these terms.

#### The signed statement is not configurable

`solana_studio/phantom_deeplink` emits `Studio.wallet_sign_in_statement`, and it
must keep doing so. studio-engine's `solana_sessions/phantom_callback`
**rebuilds** the signed message to post for verification, so the two read one
accessor precisely so they cannot drift; a caller-supplied statement would break
the signature check on every mobile sign-in. `test/web3_modals_test.rb` pins
this from both directions.

#### Choosing between the loader and your own tag

`solana_studio/deeplink_assets` **appends** a script element, so it is
asynchronous. A callback that reads `nacl` at parse time will lose that race.
Adopt the loader only together with a callback that waits; otherwise keep a
blocking `<script>` tag of your own with the same SRI-pinned URL. turf-monster
deliberately does the latter.

## Dependencies

- `ed25519` (~> 1.3) — Ed25519 signing
- Ruby stdlib only (net/http, json, digest, securerandom)
- **No Rails dependency.** `railties` is a development dependency only; the
  engine loads solely when the host has already loaded Rails.

## Development Notes

See [RUNBOOK.md](./RUNBOOK.md) for troubleshooting and local test commands.

### 🧊 The durable-nonce primitives have two consumers, and one of them is on ice

`Solana::SystemProgram` and `Solana::NonceAccount` landed together in **v0.4.6
(2026-06-02, `11ec512`)** for **two** consumers at once, and the commit says so:
*"the reusable core for the signing console's two-browser flow and for making
turf's operator tx flows expiry-immune."*

**The first of those went on ice on 2026-08-31.** McRitchie Studio's admin
signing console — N wallets signing in separate browsers, anchored on a durable
nonce so a half-signed transaction does not expire between signers — is **frozen
in place: still working, not removed, not deprecated**, and not expected to drive
any further work in this gem. Its full note (why it was frozen, and the one
question that would revive it) lives in the hub, at `docs/SIGNING_CONSOLE_V2.md`.

**Do not read that as permission to drop these two files.** The second consumer
is the one in production:

| Primitive | Live use |
|---|---|
| `Solana::SystemProgram.advance_nonce_account` | turf-monster prepends it as **instruction #0** of a durable-nonce vault cosign transaction (`app/services/solana/vault.rb`). Its cosign validator also **allow-lists exactly this one System instruction** — a nonce-anchored entry with any other System instruction is rejected. |
| `Solana::NonceAccount.parse` | turf-monster reads the on-chain nonce account in the same path. |

So the frozen consumer is the *quieter* one, never the only one. Both primitives
are byte-match tested in `test/system_program_test.rb`, and a change to either
still lands on turf-monster's money path — treat them as `onchain`, not as dead
code left over from a shelved tool.

### The browser lane

The Ruby suite cannot see three things this gem ships: whether
`network_guard.js` actually **runs** in a browser, whether
`_network_mismatch.html.erb` **renders** (rendering it needs studio-engine's modal
blocks and a view context, so `test/views_test.rb` only proves it compiles), and
whether the base58 encoder inlined in `_phantom_deeplink.html.erb` produces the
**right bytes**. That last one is signing-path code: the deep link encodes the
payload a user signs inside Phantom, so an encoder that mis-encodes yields a
signature over the wrong bytes. The failure is invisible to a String assertion —
the source is identical either way — and lands when someone taps Connect on a
phone. `e2e/phantom_deeplink.spec.js` decodes the emitted payload with its own
independent implementation and compares bytes, rather than checking the parameter
merely looks like base58.

```bash
npm ci && npx playwright install chromium
npx playwright test              # ~40s, boots its own server
npx playwright test --headed     # watch it
bin/e2e-executed-set-check       # did the lane run its WHOLE declared set?
```

The lane drives the **shipped bytes**: `e2e/boot.rb` copies the real
`app/assets/javascripts/solana_studio/network_guard.js` into the dummy's `public/`,
and the lab pages render the real partials by name. A lab page may set up a
partial's locals and nothing else — `test/e2e_lane_contract_test.rb` asserts that,
because a page that hand-rolled what the gem does would leave the specs grading the
lab while reporting green over untested gem code.

It is **not** in `bin/release-check`. It runs as a parallel CI job, so it adds ~0
to the wall time a PR waits and a release does not install a browser to publish.

**Two halves, one number.** `config/e2e_lane.yml` declares how many specs must
execute. `bin/e2e-executed-set-check` reads Playwright's own receipt after the run
and asserts the executed set against it; `test/e2e_lane_contract_test.rb` asserts
the committed specs still declare it. Static counting answers "how many are
DECLARED" and can never answer "how many RAN" — and a runtime skip, a stray
`--grep`, `--only-changed`, and an uncollected file are four spellings of the same
event. The receipt turns all four into one arithmetic failure.

Derive the counts, never hand-count them: `npx playwright test --list`.

Run the suite with `bin/release-check` — the same entry point CI and the release
gate use, so they cannot drift apart. It enumerates test files by glob (no list
to forget a file from) and **fails a file that runs zero tests or skips one**,
because a suite that quietly stops covering something is the failure a green
build cannot show you. `node` is required: the browser guard's suite runs the
shipped `.js` under node with `window`/`document` stubs.

## License

MIT
