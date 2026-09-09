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

There is **nothing to wire up**, on studio-engine **0.68.0 or newer**. The
engine's auth modal looks for a partial at one fixed path and renders whatever
it finds:

    solana_studio/auth/_wallet_credential

Bundling this gem puts that partial on the host's view path, so the button
appears. An app that does not bundle it finds nothing and renders nothing — no
wallet markup ships to a newsletter app, and no `render` call has to be deleted
to keep it out.

#### The studio-engine floor: 0.68.0

**0.68.0 is the first studio-engine that performs the lookup.** Until it, the
engine's `style/modals/_auth` drew the Solana button itself, inline, and never
consulted `solana_studio/auth/wallet_credential` at all — this gem shipped the
partial, its tests and this section for a button no host rendered. 0.68.0
deleted that inline copy and put the lookup in its place, which is what made the
paragraph above true.

Below the floor the partial is **inert, and nothing says so.** It sits on the
view path and is never asked for: no `render` runs, no button comes from it, and
no error reaches the page or the log. A host that edits the partial and sees the
modal unchanged should suspect the engine version first — that silence, not a
stack trace, is the symptom.

Derived by unpacking the published gems rather than reading a changelog: 0.67.2
contains no reference to `solana_studio/auth` anywhere in `app/`, and 0.68.0
gates the render on `lookup_context.exists?("wallet_credential",
["solana_studio/auth"], true)`. Match on the **namespace, not the basename** —
`style/modals/_wallet_connect` ships unchanged in both releases and answers an
unrelated question.

The two gems set the floor together, and the pair matters more than either
number. Every row below also assumes the host has wallet sign-in **configured
on** — `Studio.auth_method?(:wallet)` and `Studio.feature?(:web3)`, the two
questions in the table further down. McRitchie Studio leaves them off, so it
shows no wallet button on any pair of versions:

| studio-engine | this gem | The sign-in modal shows, wallet configured on |
|---|---|---|
| 0.67.2, the last release below the floor | 0.5.3+ | the **engine's own** inline button; this gem's partial renders nowhere |
| 0.68.0+ | 0.5.3+ | **this gem's partial** — the arrangement described above |
| either side of the floor | 0.5.2 | **no wallet button, silently** — see below |
| either side of the floor | not bundled | no wallet button, correctly — a web2 app ships no wallet markup |

**0.5.2 is the trap.** It shipped `solana_studio/auth/_wallet_credential`
*without* `solana_studio/modals/_wallet_connect`, and both engines gate the
button on that picker resolving (the engine's `web3_gem` gate), so the credential
partial is present, correct, and suppressed either side of the floor. 0.5.3 is
the first version of this gem shipping both paths, and so the first that can
draw the button at all.

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
members from it — `attested()` for the legal-age gate, `props.submitting` for
the disabled state, and `methodOn('wallet')` for visibility.

Only the first two are required. `methodOn` is called behind a `typeof` test, so
a host that never defined it **shows** the button rather than hiding it. A bare
call in a host without the member throws, Alpine grades the throw as falsy, and
the button **silently never renders** — no error a user can see, nothing in the
page to debug. Bundling the gem has already answered *is wallet implemented*; a
host with no toggle has expressed no opinion about showing it, and the answer to
no opinion is yes. The test stays in Alpine deliberately: Ruby decides whether
this partial exists, Alpine decides whether it shows, and folding the visibility
into Ruby brings back a floating divider on a toggle page.

#### Locals

| Local | Required | What it does |
|---|---|---|
| `modal_store` | **yes** | Alpine store name backing the modal. The engine's real host passes `"modals"`, the living style guide passes `"dsModals"`. No default on purpose: a wrong store name fails as a dead button rather than an error, so missing beats wrong. |
| `on_click` | no | Alpine expression run once the age gate passes. Defaults to swapping straight to the wallet-connect picker. Parenthesised before it is emitted, so any expression is safe to pass. |

`on_click` replaces what happens **after** `attested()` — never `attested()`
itself, which stays template text no local can reach. A seam carrying the whole
handler could drop the legal-age gate by simply never calling it, and the button
would look and behave completely normal.

Keeping the gate out of the local guarantees it is **called**. Making it
**control** what follows took one more step, because the two land side by side
in a single JavaScript expression and precedence, not the template, decides
which wins. `&&` binds tighter than `||`, `?:` and comma, so an override built
on any of those would reparse and run its tail with the gate **false**. The
override is therefore wrapped in parentheses before it is emitted, and you do
not need to bracket it yourself. Measured in Chromium against studio-engine's
vendored Alpine 3.16.1, both directions: with the gate false nothing runs, with
the gate true the whole override runs.

Pass it when the host has to do something before the picker navigates away. The
picker's redirect is unconditional, so a host holding unsaved state must write
it first. Turf Monster stages a contest lineup in `localStorage`, and adopting
the default would lose that lineup on wallet sign-in:

```erb
<%= render "solana_studio/auth/wallet_credential",
           modal_store: "modals",
           on_click: "openWalletHub()" %>
```

The expression is emitted **unescaped**, because it is developer-authored code
exactly like the template around it. Keep it free of double quotes — one closes
the attribute early and Alpine mounts the button as a silent no-op — and keep it
an **expression**: a statement (`let x = 1; foo()`) or a trailing `//` comment
is a syntax error once Alpine wraps the handler, measured both before and after
this change.

What those constraints have in common is the point. Every one of them fails
**loudly** — the button visibly does nothing. The precedence bug was the only
one that failed silently, and it is the one this change removes.

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

#### The host JavaScript these modals reach for

Every global below belongs to the **host**. This gem ships **no routes at all**,
and the JavaScript it does ship is a different category from the globals below:
`solana_studio/network_guard.js` plus the redirect-transport primitives
(`wallet_transport`, `redirect_provider`, `wallet_journal`, `wallet_ops` — see
[The wallet intent registry](#the-wallet-intent-registry-walletops)), none of
which provide any global in this table. So none of these can live here. Each is reached behind a `typeof` guard: an absent one degrades the
card rather than breaking it, and the whole point of writing the list down is
that a consumer meets it here instead of rediscovering it.

| Global | Needed by | Absent means |
|---|---|---|
| `window.solanaConnectAndVerify(name, opts)` | both | **required** — nothing can connect |
| `window.walletProvider` | both | **required** — no wallet rows paint |
| `window.handleSolanaVerifySuccess(result)` | both | no post-verify hook runs |
| `window.startPhantomDeepLink(linkMode, userId)` | picker | the mobile Phantom row is hidden |
| `parseSolanaError(msg)` | both | the wallet's raw words are shown unmapped |
| `window.reportWalletFailure(stage, provider, raw, mapped)` | both | **this surface is dark** |

##### `reportWalletFailure`, and why the endpoint is yours

Everything on the wallet surface fails **client-side**: the throw is caught,
mapped, and painted into a paragraph. Without this call nothing about it exists
outside the browser — which is how a user whose Phantom held no keypair was told
to check their USDC balance seven times in one production session (2026-09-06)
before an operator noticed by hand.

The gem calls it; it does not implement it. **The reporter and its endpoint are
host-owned because they need an `ErrorLog` this gem cannot assume** — the engine
here mounts no routes by design, so a gem-side reporter would POST at a path a
consumer is not guaranteed to have, and a report that 404s silently is strictly
worse than the silence it replaced: the surface still looks wired. Reference
implementation in turf-monster: `app/javascript/solana_errors.js`, receiving at
`POST /auth/solana/report_failure`.

The contract the call sites keep:

- **Called once per caught rejection**, with the stage for that surface —
  `'wallet_connect'` from the picker, `'web3_step_up'` from the step-up card. A
  stage the host does not recognise should be recorded, not refused; the report
  is still worth having.
- **Both message halves, always.** `raw` is what the wallet said, captured before
  the mapper runs; `mapped` is what the user read. A **mis-mapping** is invisible
  in the mapped half alone, and that is the failure the 2026-09-06 incident
  actually was — a correct mapper meeting a string it had never seen.
- **Skipped when the error is already tagged `walletFailureReported`.** Set that
  property on any error your `solanaConnectAndVerify` rethrows after substituting
  a sentence of your own, and report it from in there, where the wallet's words
  still exist. Without the tag the same failure files a second row carrying your
  sentence in both halves — the useless row, and the one an operator meets first.
- **Fire and forget.** The return value is ignored and a **throw is swallowed**.
  Do not rely on that: a reporter that throws is a bug, and the guard exists
  because an observer must never become the incident.
- **Four values, and only these four.** No signature, no nonce, no signed SIWS
  message — the modals never hold any of them, so none can leak. `raw` is free
  text a **wallet** composed, so scrub it **server-side**: a wallet can quote your
  own nonce back at you inside a field your key allowlist has already approved. A
  pubkey is fine and should be kept; over-redaction blinds the tool.

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

### The wallet intent registry (`walletOps`)

`solana_studio/wallet_ops.js` is how one piece of product logic — enter a
contest, rename a user, export a wallet — runs over **both** wallet transports
from **one** call site. The inline transport is an injected provider where
`await` works; the redirect transport hands off to a wallet app by URL and the
page is destroyed mid-operation. A flow is declared once, by name:

```js
SolanaStudio.walletOps.define('contest_entry', {
  prepare:  function (ctx) { /* → { transaction: '<base58>', ...state } */ },
  complete: function (ctx, result, state) { /* result.signedTransaction is base58 */ },
  signOnly: true
});

SolanaStudio.walletOps.run('contest_entry', { contestId: 12 }, {
  provider: walletProvider.detect(),
  expectedAccount: session.address,          // optional
  appUrl: location.origin,                   // redirect transport only
  redirectLink: location.origin + '/auth/phantom/callback',
  cluster: document.body.dataset.solanaCluster
});
```

Handlers are registered **by name at page load**, never passed as closures: a
closure is precisely what cannot survive the redirect. Everything the flow needs
on the far side travels as JSON in the journal.

#### The transaction is base58 wire bytes, on every transport

`prepare()` **must** return `{ transaction: '<base58>' }`, and `complete()` is
handed base58 in `result.signedTransaction`, whichever transport ran. A
transaction that is not a non-empty string is refused by name at the call site,
on both paths.

This is not a preference. Base58 is what survives a page death; a
`solanaWeb3.Transaction` serialises into a journal as `{}`. Until 0.9.1 only the
redirect path obeyed it — the inline path passed `prepared.transaction` straight
to `provider.signTransaction`, which for an injected wallet must be a Transaction
**object** — so a single intent could not serve both transports and every
consumer kept a second, hand-rolled desktop call site.

#### The inline provider's transaction codec

The gem cannot convert between the two shapes: deserializing base58 into a
Transaction needs `@solana/web3.js`, and the only JavaScript dependency here is
a guarded `window.nacl`. Taking web3.js would put a browser library on the
critical path of a gem whose other consumers are plain-Ruby, to do work your
wallet adapter already does.

So the conversion is the **inline provider's**, and it is required in both
directions:

| Method | Given | Returns |
|---|---|---|
| `deserializeTransaction(base58)` | base58 wire bytes | whatever your `signTransaction` accepts |
| `serializeTransaction(signed)` | whatever `signTransaction` resolved | base58 wire bytes |

Both are checked **before** the wallet is touched, and an inline provider missing
either is refused by name — a base58 string reaching an extension's
`signTransaction` throws `t.serialize is not a function` from inside someone
else's code, and a missing `serializeTransaction` would not surface until after
the user had already approved a signature.

The return leg is not garnish. Without `serializeTransaction` the redirect path
hands `complete` a base58 string and the inline path hands it a signed
Transaction object, your call site branches on which, and nothing has been
unified.

A reference adapter, for a **co-signed** transaction — the server fills a second
signer slot, so both serialize flags are off and a bare `signed.serialize()`
would throw on the missing signature:

```js
var base58 = SolanaStudio.walletTransport.base58;

inlineProvider.deserializeTransaction = function (wire) {
  return solanaWeb3.Transaction.from(base58.decode(wire));
};

inlineProvider.serializeTransaction = function (signed) {
  return base58.encode(
    signed.serialize({ requireAllSignatures: false, verifySignatures: false })
  );
};
```

Write it once, on the object your `detect()` returns, and every intent in the app
is covered. Putting it on the intent instead is the same three lines of web3.js
copied into each flow — per-call-site duplication wearing a different hat.

#### `expectedAccount` — a UX guard, not a security one

`run(..., { expectedAccount: '<base58 address>' })` declares which account the
caller believes it is about to use, and walletOps refuses the trip when a
different one connects. **The ownership proof is on-chain** — Anchor rejects a
transaction whose signer does not match the PDA's owner, with or without this.
What the declaration buys is a sentence the user can act on instead of a program
error, plus, on the inline transport, a server-minted prepared transaction that
is never wasted.

The refusal carries `err.wrongAccount === true` and the full `err.expected` /
`err.connected` addresses, so a host can compose its own sentence rather than
parse the default one.

It is a **string**, not a `PublicKey`, and a non-string is refused: a PublicKey
would stringify correctly inline and be journalled as `{}` on the redirect path,
matching on a desktop and refusing every mobile trip.

Where it is checked, and what that costs, differs by transport — this is the one
place the two genuinely cannot be made identical:

| Transport | Checked | Cost of a wrong wallet |
|---|---|---|
| Inline | after `connect()`, **before** `prepare()` | nothing — `prepare` never runs |
| Redirect, cold session | on the connect callback, **before** the signing hop | whatever `prepare` already minted; no signing prompt |
| Redirect, warm session (`opts.session`) | **not checked** | — |

The redirect path cannot check earlier because the connect hop destroys the
page: everything `prepare` returns must already be in the journal before the
navigation. A warm session takes no connect hop at all, so walletOps never learns
an account — a caller holding a session learned the address when it established
one, and that is where the check belongs.

It is a declared **value** rather than a post-connect hook on purpose. The
connect callback is a different document — in this ecosystem, studio-engine's
wallet callback view, which knows nothing about any consumer's flows — and
`resume` deliberately does not require a registered handler to advance from
connect to signing. A hook would be looked up on exactly the hop it exists to
guard, come back empty, and be skipped in silence.

#### `signOnly`

A **co-signed** transaction cannot be broadcast by the wallet: the chain rejects
it for the missing signature, and the signed bytes the server needs never come
back. `signOnly: true` makes the transaction's requirement outrank the wallet's
capability, so the trip takes `signTransaction` even on Solflare and Backpack,
which do ship a send-side deeplink. Omit it and nothing changes: a wallet that
can broadcast still does. It is a boolean or it is refused.

#### What `walletOps` does not do

It does not broadcast, and it mounts no routes. `complete` is told which side
sent — `sendStrategy` is `'app-broadcasts'` or `'wallet-broadcasts'` — and owns
the RPC. The redirect leg also needs a host callback page to call
`walletOps.resume(params, { navigate })`; studio-engine's
`solana_sessions/phantom_callback` does this from 0.73.0.

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
