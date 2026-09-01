# Changelog

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- **The wallet sign-in button, contributed into studio-engine's auth modal** (`app/views/solana_studio/auth/_wallet_credential.html.erb`). Part of the base/bolt-on split: studio-engine plus McRitchie Studio is the template every app is built from, web2 and web3 alike, and this gem plus Turf Monster is the web3 bolt-on. Sign-in is a base concern so the modal stays in the engine; **wallets are not**, so the button moved here. The engine renders whatever resolves at `solana_studio/auth/wallet_credential` and nothing when the path is empty, so bundling this gem IS the registration and a web2 app carries no wallet markup at all. Deliberately NOT solved by giving this gem its own auth modal: that would fork a surface both apps sign in through, which is how the wallet picker reached three drifting copies before it was promoted. The engine keeps both halves of the existing gate (`Studio.auth_method?(:wallet)` and `Studio.feature?(:web3)`) so the hub — which bundles this gem for its signing primitives with web3 off — still renders a web2 sign-in modal.

### Tests
- `test/auth_credential_test.rb` (7): the partial sits at the path the engine resolves, the click handler consults the modal's age gate, visibility binds to the shared `methodOn('wallet')` toggle, `modal_store` is required with no default, the swap carries the picker's `backTo`/`ageAttested` contract, the brand gradient id is namespaced against collisions, and the mark stays inline rather than becoming a sprockets asset request. Every assertion reads ERB-comment-stripped source, because this file documents its own contract in prose and a bare grep would match the paragraph instead of the code — proven by mutating the gate into a comment and watching it go red.
- `test/gemspec_test.rb` and `.github/workflows/gem-ci.yml` name the new partial alongside the modal, so a `spec.files` glob that stopped matching it fails at build rather than in a consumer.

## Unreleased — targets v0.5.0 (minor)

Ships the gem's first Rails half, and its first CI. The version number is
allocated by the release conductor, not by this entry.

### Added
- **The browser lane** — a real Chromium against the gem's real onchain surface. `e2e/boot.rb` serves a minimal `test/dummy` host (no `bin/rails`, no `config.ru`, no database — the partial's only inputs are locals and one data attribute) and COPIES the shipped `network_guard.js` into it, so the specs drive the bytes a consumer installs rather than a re-typed copy. Runs as a PARALLEL CI job, ~40s, and is deliberately not in `bin/release-check`: a release should not install a browser to publish. Pieces: `playwright.config.js`, `e2e/*.spec.js`, `test/dummy/`, `config/e2e_lane.yml`, `bin/e2e-executed-set-check`, `test/e2e_lane_contract_test.rb`.
- **`config/e2e_lane.yml` + `bin/e2e-executed-set-check`** — the lane's verdict gate. A test lane can report that its specs PASSED; it structurally cannot report that it RAN THEM ALL. The gate reads Playwright's own receipt and asserts `expected == total_specs && skipped == 0 && unexpected == 0`, so a runtime `testInfo.skip()`, a `--grep`, `--only-changed` and an uncollected file all surface as one arithmetic failure instead of four invisible ones. It also refuses a `--list` receipt by name rather than reading it as a catastrophic failure, and NAMES an unreadable one — a run killed mid-write leaves a truncated file, and "the lane never finished" and "the gate is broken" are different findings that a bare parse error makes look identical. Mutation-proven ELEVEN ways, every mode red: a runtime skip, a `--grep`, a dropped spec file, a stale total, per-file drift that keeps the total right, a missing receipt, a `--list` receipt, an all-zero receipt, a truncated receipt, a receipt that is not a Playwright report, and a `grepInvert`/`shard` added to the config.

### Fixed
- **The network-mismatch modal leaked `%>` into the rendered card.** Its header comment spelled the registration example out in real ERB tags, and the example's own closing marker ended the comment early — so the remaining prose rendered as literal text in the card, and the broken structure took Alpine down with it (`Cannot set properties of null`). It compiled, so `test/views_test.rb` was green; it passed review, CI and 114 tests. **The browser lane caught it on its first real run**, which is the clearest possible statement of what the lane is for. The comment now describes the integration in words; the runnable example lives in the README, where a stray marker cannot escape into a page.
- The modal's documented host requirements now name the one that is easy to miss: an **ancestor `x-data` scope** (normally a bare `x-data` on the host's `<body>`). studio-engine's modal host roots itself at a `template x-if` with no `x-data` of its own, and Alpine only walks trees beneath an `x-data` root — without it the host is never processed, the modal never opens, and the served HTML looks perfectly correct.

### Tests
- `test/e2e_lane_contract_test.rb` (9): the contract names exactly the spec files that exist, per-file counts match the committed specs, the total equals their sum, no spec or config can narrow the set (`test.only`, `testInfo.skip`, `test.fixme`, `grep`, `grepInvert`, `--only-changed`, `testIgnore`, `testMatch`, `shard`, retries), the lab renders the gem's real partials by name, `boot.rb` copies the real assets, and the layout supplies the Alpine root the host requires.
- `test/e2e_executed_set_test.rb` (10): the gate's arithmetic without a browser — a clean run, a runtime skip, a failure, a narrowed run, a spec moved between files, a `--list` receipt, a truncated receipt, valid JSON that is not a Playwright report, a real receipt parsing, and nested-suite flattening.

### Added
- **`Solana::Network`** — cluster identity, Rails-free and RPC-free. Pinned genesis hashes for mainnet-beta/devnet/testnet, `cluster_for_genesis` (what an RPC URL *actually* points at, as opposed to what its hostname claims), Wallet Standard chain ids, alias normalization, and `expected_for_environment`. `alignment(cluster:, genesis_hash:)` returns **three** states — `:aligned`, `:mismatched`, `:unverifiable` — because localnet has no pinnable genesis and an unknown cluster name has no hash to compare: collapsing `:unverifiable` into `:mismatched` refuses to boot every local validator, and collapsing it into `:aligned` trusts a chain nobody checked.
- **`SolanaStudio::Engine`** — an **optional** Rails engine, required only when `Rails::Engine` is already defined. `railties` is deliberately NOT a runtime dependency: plain-Ruby consumers (chain-ops scripts, rake tasks, `ruby -e`) load the gem exactly as before and never install Rails. Both directions are asserted, in separate subprocesses, in `test/engine_test.rb`.
- **`solana_studio/modals/_network_mismatch`** — the network-mismatch explainer modal, rendering through studio-engine's shared modal blocks.
- **`solana_studio/network_guard.js`** — `SolanaStudio.network`, a validation wrapper for onchain actions. A website **cannot** read which network a wallet is set to (Phantom does not expose it; the Wallet Standard `chains` array lists what a wallet supports, not what it selected), so the guard does the only two things that work: `withSignInChainId` asserts the app's cluster as a SIWS `chainId` and lets the wallet contradict it, and `guard(fn, {onHint})` classifies a *failure* after the fact. It never blocks, and it re-throws the original rejection untouched — a hint beside the real error, never instead of it. `classify` is calibrated to under-claim, and precedence is what makes that true: a custom program error means the program RAN on a chain that has it, so it outranks the "Transaction simulation failed" wrapper that Solana puts around every failed simulation. Without that ordering an ordinary "contest is full" classified as a probable network problem at top confidence — the exact wrong-thing-to-fix this feature exists to prevent, in the feature's own voice.
- **`bin/release-check`** — one entry point for local cert, CI, and release. Enumerates test files by glob (no curated list to drift) and fails any file that runs **zero** tests or **skips** one.
- **`.github/workflows/gem-ci.yml`** — the gem's first CI lane. Runs the suite, builds the gem, and asserts the engine's files are inside the **built artifact** (a manifest can be right while the build excludes a file; only the artifact is what a consumer installs).

### Changed
- **`spec.files` now includes `app/**/*`.** This is the highest-consequence line in the gemspec: the release sweep publishes on membership rather than content, so a view left outside this glob would ship an engine with no views in it — green suite, green CI, green sweep, and a `missing partial` raised in a consumer app. `test/gemspec_test.rb` asserts the **invariant** (every file in a shipped tree is in the manifest) rather than a filename checklist, which would pass forever while the next new file escaped.

### Tests
- `test/network_test.rb` (13): genesis hashes asserted literally rather than round-tripped through the table that defines them; the three-state alignment, each state separately; `canonical` returning nil rather than a default for an unknown name; and that no boolean exists to collapse the third state.
- `test/engine_test.rb` (6): the conditional in both directions, in separate processes (`require` is idempotent, so one process cannot observe both).
- `test/gemspec_test.rb` (8): the packaging invariant, no directory entries, the version file's single literal asserted with the RELEASE CONDUCTOR'S OWN regex rather than a proxy for it, the gemspec holding no literal of its own, and no Rails runtime dependency.
- `test/network_guard_js_test.rb` (18): the classifier under node, including the inversion found in review — a custom program error outranks the "Transaction simulation failed" wrapper, so a full contest is never reported as a network problem — plus the wrapper's transparency: original error re-thrown, success passed through, a throwing hint callback unable to replace the real error.
- `test/views_test.rb` (3): every shipped ERB template compiles under **ActionView's** Erubi (stdlib ERB cannot compile the `render … do` block form), the glob is non-empty, and the modal still renders the wallet's own error text.

## v0.4.7 (2026-06-05)

### Added
- **`Solana::Transaction.cosign_wire(signed_wire_bytes, signer:, require_complete:)`** — client-first cosign. Adds one signature to an already-(partially-)signed wire tx WITHOUT rebuilding it: parses the compact-u16 signature count + message header, finds the signer's account-key index, asserts that slot is currently zero (never clobbers a real signature), signs the EXACT message bytes, writes the 64-byte signature in, and (when `require_complete:`, default true) re-asserts OPSEC-017 — every required slot non-zero. Pure Ruby, no RPC. Enables the Phantom-signs-FIRST / server-cosigns-SECOND entry flow that clears Phantom's multi-signer-order "could be malicious" Lighthouse banner. `cosign_wire_base64` is the base64 wrapper.
- **`Solana::Transaction.read_compact_u16(bytes, offset)`** — ShortVec compact-u16 decoder, `[value, next_offset]` (wire-parser primitive behind `cosign_wire`).
- **`Solana::Client#simulate_transaction(tx_base64, sig_verify:, replace_recent_blockhash:, commitment:)`** — server-side `simulateTransaction` pre-flight; returns the RPC `value` object (`err`/`logs`/`unitsConsumed`). Lets the server run the same pre-broadcast simulation the entry board did client-side, now that broadcast moved server-side.

### Tests
- `test/transaction_test.rb` (+9 tests): correct slot filled + verifies over message, other signer's sig + message bytes untouched, 2/2 sigs valid, refuses to clobber a filled slot, rejects a non-signer, off-by-one slot guard, malformed-header count-mismatch rejection, base64 round-trip.
- `test/client_test.rb` (+2 tests): simulate_transaction sends the right RPC + parses `value`; surfaces a program error in `value["err"]`.

## v0.4.6 (2026-06-02)

### Added
- **`Solana::SystemProgram`** — System-Program instruction encoders for durable nonce support: `create_account` (ix 0), `advance_nonce_account` (4), `withdraw_nonce_account` (5), `initialize_nonce_account` (6), `authorize_nonce_account` (7). Plus constants `RECENT_BLOCKHASHES_SYSVAR`, `RENT_SYSVAR`, `NONCE_ACCOUNT_LENGTH` (80). A durable nonce lets a tx stay valid indefinitely (until consumed) instead of expiring with a ~90s recent blockhash — the canonical pattern for long / async / multi-party signing.
- **`Solana::NonceAccount.parse(bytes)`** — parses an 80-byte nonce account (version, state, authority, stored nonce, lamports_per_signature) with `initialized?` + `authority?(expected)` guards.

### Tests
- `test/system_program_test.rb` (8 tests): **byte-match** each encoder against the exact `@solana/web3.js` layout (u32 LE index + fields, account metas + signer flags), nonce-account parse round-trip (init + uninit), and an advance-instruction-into-partial-tx composition check.

## v0.4.5 (2026-06-02)

### Fixed
- **Fully keyless `serialize_partial`** — a build with zero local `@signers` (every required signature supplied externally) now works: the empty-signers guard fires only when neither a local nor an additional signer is present, the fee payer falls back to the first additional signer, and `@signers.drop(1)` is nil-safe. Enables the no-server-key multi-party signing console. (v0.4.4 began this; v0.4.5 completed the fee-payer/signers fallback.)

## v0.4.3 (2026-05-27)

### Fixed
- **`Solana::Client#http_post` now preserves the query string when constructing the `Net::HTTP::Post` path** (was: dropped). RPC providers that carry their API key on the query — Helius (`https://devnet.helius-rpc.com/?api-key=…`), QuickNode, Triton — previously received an authless request and replied with their equivalent of `"missing api key"`, breaking every RPC call. `@uri.request_uri` is the correct accessor (path + "?" + query); `@uri.path` returns only the path portion. Surfaced when turf-monster moved off the public devnet endpoint to Helius.

### Tests
- New `test/client_test.rb` (2 tests): asserts `http_post` builds the request with the full request-URI (path + query) when the RPC URL carries a query string, and falls back to `"/"` when path is empty.

## v0.4.2 (2026-05-19)

Tier-3 fixes from the turf-monster pre-prod opsec audit (OPSEC-017/018/043).

### Changed (breaking)
- **`Solana::AuthVerifier.verify!` now requires an `expected_host:` keyword argument (OPSEC-018).** The verifier previously matched only the nonce, so a signature a user produced for any other dApp — over a message carrying the same nonce — would satisfy a host app's login. `verify!` now asserts the signed message names `expected_host` as its opening token (SIWS-style `"<host> wants to sign in…"`). Callers must pass `expected_host:` (e.g. `request.host`).

### Fixed (security)
- **`Solana::Transaction#serialize` / `#serialize_partial` now verify signer count (OPSEC-017).** `serialize` raises unless `@signers.length` equals the number of `is_signer` accounts; `serialize_partial` raises unless local + additional signers cover every required slot. Previously a missing required signer produced a malformed payload, or a zero-filled signature slot in a still-broadcastable half-signed TX.
- **`Solana::Transaction#serialize_partial` no longer stores signer state in an instance variable (OPSEC-043).** Additional signers are kept in a local, so a `Transaction` shared across threads can't leak signer state between partial-sign flows.

### Tests
- New `test/auth_verifier_test.rb`; added signer-count + no-instance-state cases to `test/transaction_test.rb`.

## v0.4.1 (2026-05-17)

Pre-public-release security hardening per `SECURITY-AUDIT-2026-05-17.md`.

### Fixed (security)
- **TLS enforcement in `Solana::Client`** — explicit `OpenSSL::SSL::VERIFY_PEER` and `TLS1_2_VERSION` minimum on every HTTPS RPC connection. Belt-and-suspenders against future downstream Net::HTTP regressions.
- **HTTPS-only RPC URL validation** — `Solana::Client` constructor now raises `Solana::Client::InsecureRpcUrlError` on `http://` URLs unless the host is `localhost`/`127.0.0.1`/`::1`. Prevents cleartext RPC traffic to public providers.
- **Borsh allocation-bomb guard** — `Solana::Borsh::MAX_DECODED_FIELD_BYTES = 10MB`. New `decode_string` + `decode_vec` helpers check the length prefix before allocating; raise `Solana::Borsh::DecodedFieldTooLarge` on overage. Protects callers from corrupt or malicious RPC responses.
- **Constant-time nonce compare in `Solana::AuthVerifier`** — `OpenSSL.fixed_length_secure_compare` replaces Ruby string `==`. Removes a (low-practical-impact) timing side channel.
- **Pubkey + signature length validation in `Solana::AuthVerifier.verify!`** — explicit checks before `Ed25519::VerifyKey.new` so malformed inputs raise `VerificationError("Public key must be 32 bytes...")` instead of being masked by the generic `"Signature verification failed"` catch-all.
- **Base58 input validation in `Solana::Keypair.decode_base58`** — explicit alphabet check raises `ArgumentError` with a clear message on invalid chars (`0`, `O`, `I`, `l`) instead of producing a confusing `TypeError` deep in the multiplication loop.

### Changed
- `Solana::AuthVerifier` docstring now loudly states caller's responsibility for nonce invalidation (delete-before-verify pattern) and links to the canonical Rails session-adapter at `turf-monster/app/controllers/concerns/solana/session_auth.rb`.
- Gemspec author email changed from `alex@mcritchie.studio` (personal) to `solana-studio@mcritchie.studio` (project alias).

## v0.4.0 (2026-05-17)

### Changed (breaking)
- **Gem renamed from `solana_studio` to `solana-studio`.** Repo URL is now `github.com/amcritchie/solana-studio` (was `.../solana_studio`). Consumers must update their `Gemfile`:
  ```ruby
  # Before:
  gem "solana_studio", git: "https://github.com/amcritchie/solana_studio.git", tag: "v0.3.0"
  # After:
  gem "solana-studio", git: "https://github.com/amcritchie/solana-studio.git", tag: "v0.4.0"
  ```
- The Ruby `SolanaStudio` module name and the `Solana::*` namespace are **unchanged** — all call sites keep working without code changes.
- Gem entry point at `lib/solana-studio.rb` (a thin `require_relative "solana_studio"` shim) ensures `gem "solana-studio"` auto-requires correctly without a `require:` option in the Gemfile.

### Added
- gemspec `metadata` (homepage / source / bugs / changelog URIs) — getting ready for RubyGems publishing.

## v0.3.0 (2026-05-17)

### Added
- **`Solana::AuthVerifier`** — pure module for verifying Phantom wallet signatures against an externally-stored nonce. Extracted from turf-monster's `app/services/solana/auth_verifier.rb`. Host apps keep a thin session adapter that delegates to `Solana::AuthVerifier.verify!`.
- `Solana::AuthVerifier::VerificationError`, `Solana::AuthVerifier::NONCE_MAX_AGE` constants now live in the gem.
- Updated CLAUDE.md with the gem-vs-app split rule for Solana code.

### Fixed
- gemspec `spec.version` was bumped to "0.3.0" after the initial release (had been mistakenly left at "0.2.0").

## v0.2.0 (2026-04-03)

- SPL Token instruction builders (`create_associated_token_account`, `mint_to`, `transfer`)
- Test suite: Keypair, Borsh, and Transaction tests (9 tests)
- Updated CLAUDE.md with test documentation

## v0.1.0 (2026-04-02)

- Initial release
- `Solana::Client` — JSON-RPC over HTTP with retry logic
- `Solana::Keypair` — Ed25519 keygen, base58, sign, `from_base58` for env var loading
- `Solana::Borsh` — encode/decode primitives (u8, u16, u32, u64, i64, pubkey, string, vec, bool)
- `Solana::Transaction` — transaction builder, PDA derivation, Anchor discriminators, on_curve? check
