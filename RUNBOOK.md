# Runbook -- SolanaStudio Gem

Troubleshooting guide for autonomous agents. Format: problem, diagnosis, fix.

## RPC Connection Failures

**Timeout connecting to RPC**
- Diagnosis: `Net::OpenTimeout` or `Net::ReadTimeout` from `Solana::Client`. The RPC node is slow, down, or unreachable.
- Fix: Check the URL: `Solana::Client.new.instance_variable_get(:@rpc_url)`. Defaults to `ENV["SOLANA_RPC_URL"]` or `https://api.devnet.solana.com`. Test manually: `curl -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getVersion"}' <rpc_url>`. Switch to a provider RPC if the public endpoint is down.

**Wrong RPC URL (nil or empty)**
- Diagnosis: Client silently defaults to devnet public RPC when `SOLANA_RPC_URL` is unset. Transactions land on the wrong network.
- Fix: Set the env var explicitly. In Rails: check `.env` file. On Heroku: `heroku config:get SOLANA_RPC_URL --app <app>`.

**Rate limit (HTTP 429)**
- Diagnosis: `Solana::Client` retries on 429 automatically (built-in retry logic). If retries are exhausted, the call raises.
- Fix: Reduce call frequency or switch to a paid RPC endpoint with higher rate limits. The client retries with backoff -- check `send_rpc` for the retry count and delay.

**Expired blockhash on retry**
- Diagnosis: Transaction built with one blockhash, but by the time it's submitted after retries, the blockhash has expired. Error: `Blockhash not found`.
- Fix: The client's retry logic handles this by re-fetching the blockhash. If it still fails, the transaction was too slow to build. Simplify the transaction or fetch a fresh blockhash immediately before signing: `client.get_latest_blockhash`.

## Keypair Loading Errors

**Bad base58 string**
- Diagnosis: `Solana::Keypair.from_base58(str)` raises on invalid characters or wrong length. Base58 uses `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz` (no 0, O, I, l).
- Fix: Verify the string: `Solana::Keypair.from_base58(ENV["SOLANA_ADMIN_KEY"]).address`. If it raises, the key is malformed. Re-export from the source (1Password, Solana CLI JSON file). A valid Solana secret key is 64 bytes (88 base58 characters).

**Missing `SOLANA_ADMIN_KEY` env var**
- Diagnosis: `ENV["SOLANA_ADMIN_KEY"]` returns nil. Keypair creation fails with nil input.
- Fix: Set the env var. Locally: add to `.env`. On Heroku: `heroku config:set SOLANA_ADMIN_KEY=<base58_private_key> --app <app>`. The key is the Alex Bot base58 private key (from 1Password).

**JSON file keypair loading**
- Diagnosis: `Solana::Keypair.from_json_file(path)` reads a Solana CLI JSON key file (array of 64 integers).
- Fix: Verify the file exists and contains a JSON array of 64 numbers: `ruby -e "require 'json'; p JSON.parse(File.read('~/.config/solana/id.json')).length"`. Should print `64`.

## Transaction Failures

**Expired blockhash**
- Diagnosis: `Transaction simulation failed: Blockhash not found`. Blockhashes expire after ~60 seconds.
- Fix: Fetch the blockhash as close to signing as possible. Do not cache blockhashes. Pattern: `blockhash = client.get_latest_blockhash; tx.sign(keypairs, blockhash); client.send_transaction(tx.serialize)`.

**Insufficient SOL for transaction fees**
- Diagnosis: `Transaction simulation failed: Attempt to debit an account but found no record of a prior credit`. The signing account has no SOL.
- Fix: Fund the account. Follow the devnet faucet protocol: (1) `devnet-pow mine --target-lamports 2000000000 -ud`, (2) QuickNode faucet, (3) Solana Foundation faucet, (4) `solana airdrop 1 --url devnet`, (5) transfer from another funded wallet.

**PDA derivation mismatch**
- Diagnosis: `Transaction.find_pda(program_id, seeds)` returns a different address than expected. Seeds or program ID don't match what the on-chain program expects.
- Fix: Verify seeds match exactly. PDA seeds are order-sensitive and byte-exact. Common issues: string encoding (UTF-8 vs raw bytes), pubkey as 32-byte binary (not base58 string). Example: `Transaction.find_pda("7Hy8...", [b"vault"])` for the vault PDA.

**Anchor discriminator mismatch**
- Diagnosis: Transaction rejected with "Program log: AnchorError ... InstructionFallbackNotFound". The 8-byte discriminator doesn't match.
- Fix: `Transaction.anchor_discriminator("instruction_name")` must match the Anchor program's expected discriminator. The name is the snake_case Rust function name prefixed with `global:` -- e.g. `anchor_discriminator("global:create_contest")`. Verify against the IDL.

## Zeitwerk Autoload Conflict

**App's Solana::Keypair reopening not loaded**
- Diagnosis: Consumer app (Turf Monster) reopens `Solana::Keypair` in `app/services/solana/keypair.rb` to add `admin`, `encrypt`, `from_encrypted` methods. But the gem defines `Solana::Keypair` at boot, so Zeitwerk sees the constant as already defined and skips autoloading.
- Fix: The consuming app must explicitly require the file in an initializer. Create `config/initializers/solana.rb` with: `require Rails.root.join("app/services/solana/keypair")`. This is already done in Turf Monster -- if the methods are missing, check that this initializer exists.

## Running Tests

**Test command**
```bash
cd /Users/alex/projects/solana-studio
bin/release-check          # the whole suite, one file at a time
bin/release-check --list   # what it will run, in order
```
`bin/release-check` is the one entry point local certs, CI, and the release
sweep all share, so those three cannot drift apart. It enumerates by glob
(`find test -name '*_test.rb'`), so a new test file is covered the moment it
lands and there is no curated list to forget one from. It also fails a file
that runs ZERO tests or SKIPS one — a suite that quietly stops covering
something is the failure a green build cannot show you.

Run one file directly while iterating: `bundle exec ruby -Itest test/keypair_test.rb`.

The JS lanes shell out to node and FAIL rather than skip when a dependency is
missing, deliberately — the gem's suite refuses a skip, because a lane that
vanishes for want of a dependency looks identical to a lane that passed. There
are TWO such dependencies and they fail with different messages and different
fixes; read the message before reaching for a remedy.

**JS tests fail with `node is required to run this suite`**
- Diagnosis: node itself is absent from `PATH`. Every `test/*_js_test.rb` file
  probes `node --version` once and asserts on it, so this one takes out ALL of
  them at once — the assertion is a property of the lane, not a list of files
  to keep current.
- Fix: install node (CI pins 20 via `actions/setup-node` in
  `.github/workflows/gem-ci.yml`), then re-run.

**JS tests fail with `tweetnacl is required for the crypto round trips`**
- Diagnosis: node is present but a FRESH checkout or worktree has no
  `node_modules` — the lanes load the REAL tweetnacl by absolute path from
  `node_modules/tweetnacl`. Only the two lanes that do crypto round trips call
  `require_nacl!` and can emit this: `test/wallet_ops_js_test.rb` and
  `test/redirect_provider_js_test.rb`. The other `*_js_test.rb` files stub
  their own crypto and never touch `node_modules`, so seeing them red means you
  are looking at the node case above, not this one.
- Fix: `npm ci` in the gem root, then re-run. Do this before the first
  `bin/release-check` on any new worktree; CI does the same (`npm ci` precedes
  `bin/release-check` in `.github/workflows/gem-ci.yml`).

**Test fails with missing `ed25519` gem**
- Diagnosis: The only runtime dependency. `LoadError: cannot load such file -- ed25519`.
- Fix: `cd /Users/alex/projects/solana-studio && bundle install`. The gemspec requires `ed25519 ~> 1.3`.

**`test/docs/changelog_structure_test.rb` is red**
- Diagnosis: `CHANGELOG.md`'s shape, not its prose. The assertion that usually
  fires is the drift guard — `SolanaStudio::VERSION` more than two minor
  versions ahead of the newest `## ` heading, which means releases went out
  while their entries stayed under `## Unreleased`. The others catch a second
  `## Unreleased`, a heading that is not `## vX.Y.Z (YYYY-MM-DD)`, versions out
  of order or listed twice, and a `### ` above the first `## `.
- Fix: move each stranded entry under the version that actually shipped it,
  newest first. Attribute by git history, never by position in the file: `git
  blame -w -M` on the line, `git log --reverse -S'<entry text>' -- CHANGELOG.md`,
  and `git show <tag>:CHANGELOG.md` at each release tag agreeing is the
  evidence. Leave anything you cannot place confidently under `## Unreleased`
  and say so — a wrongly attributed changelog is worse than a long one. A
  release that recorded nothing keeps a heading with no entries under it.
- Note: this guard stands alone today. The hub's `bin/release prepare` does not
  read `CHANGELOG.md` at all yet — the change that makes it roll the bucket at
  every gem publish, and REFUSE while this drift exists, is pending in
  mcritchie-studio PR #1344 (`release-prepare-skips-changelog`, still open).
  Once that lands, a red run here is the same defect the release conductor
  would stop on, caught earlier. Until it lands, nothing but this test is
  watching.

**Adding new tests**
- Tests are plain minitest files in `test/`. No Rails, no fixtures. Each test file requires `test_helper.rb` which loads the gem. To add a test for `Solana::Client`, create `test/client_test.rb` following the existing pattern.
