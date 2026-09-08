require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

# The redirect transport's provider surface, exercised in a real JS engine.
#
# WHY THERE IS ONE FACTORY AND THREE WALLETS RATHER THAN THREE ADAPTERS. The
# three protocols differ only in data that already lives in
# walletTransport.PROFILES, so the behaviour is written once and parameterised.
# That decision moves the risk here: with one code path, a per-wallet difference
# is only real if a test asserts it PER WALLET. Every divergence below is
# therefore driven across all three, not spot-checked on one.
#
# CRYPTO IS REAL HERE, NOT STUBBED. A stub shaped from the code under test
# certifies the code's own assumptions and nothing else, and the round trips
# below are exactly where a wrong key or a swapped nonce would hide. The tests
# that need it resolve the gem's own tweetnacl and SKIP LOUDLY when it is
# missing, rather than quietly passing over a fake.
class RedirectProviderJsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CORE = File.join(ROOT, "app/assets/javascripts/solana_studio/wallet_transport.js")
  PROVIDER = File.join(ROOT, "app/assets/javascripts/solana_studio/redirect_provider.js")
  NACL = File.join(ROOT, "node_modules/tweetnacl")

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  def setup
    skip "node not available" unless self.class.node?
  end

  def require_nacl!
    return if Dir.exist?(NACL)
    skip "tweetnacl not installed — run `npm install` in the gem root"
  end

  # `nacl:` loads the REAL tweetnacl by absolute path (the harness runs from a
  # tempdir, so bare require() would not resolve it).
  def run_js(script, nacl: false)
    harness = <<~JS
      global.window = global;
      #{nacl ? "global.nacl = require(#{NACL.to_json});" : ""}
      #{File.read(CORE)}
      #{File.read(PROVIDER)}
      var R = window.SolanaStudio.redirectProvider;
      var T = window.SolanaStudio.walletTransport;
      var RESULT = (function() { #{script} })();
      console.log(JSON.stringify(RESULT));
    JS

    Tempfile.create(["redirect_provider", ".js"]) do |f|
      f.write(harness)
      f.flush
      # Separate streams, for the reason network_guard_js_test.rb records.
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      JSON.parse(out)
    end
  end

  # --- enumeration and capability -----------------------------------------

  def test_all_three_wallets_are_reachable_over_the_redirect_transport
    # This is what a picker enumerates on a phone. Before this existed, a phone
    # got a Phantom deep link and a DESKTOP EXTENSION DOWNLOAD PAGE for the other
    # two — a silent dead end.
    result = run_js("return R.all().map(function(p) { return [p.key, p.transport]; });")
    assert_equal [["phantom", "redirect"], ["solflare", "redirect"], ["backpack", "redirect"]], result
  end

  def test_unknown_wallet_returns_null_rather_than_throwing
    # Callers enumerate and ask; a wallet we have never heard of is a "no".
    assert_nil run_js("return R.forWallet('nonesuch');")
  end

  def test_send_strategy_splits_phantom_from_the_other_two
    # The deprecation is DATA, not a special case in the provider. Driven across
    # all three so collapsing the profile table fails here.
    result = run_js(<<~JS)
      return R.all().map(function(p) { return [p.key, p.sendStrategy(), p.can('signAndSendTransaction')]; });
    JS
    assert_equal ["phantom", "app-broadcasts", false], result[0]
    assert_equal ["solflare", "wallet-broadcasts", true], result[1]
    assert_equal ["backpack", "wallet-broadcasts", true], result[2]
  end

  def test_sign_and_send_is_refused_on_phantom_by_name
    # The refusal must name the wallet — a generic throw reads as a core bug
    # rather than as the vendor deprecation it is.
    result = run_js(<<~JS)
      try {
        R.forWallet('phantom').beginSignAndSendTransaction({ journal: { v: 1, step: 'connected' }, transaction: 'TX' });
        return 'built';
      } catch (e) { return e.message; }
    JS
    assert_includes result, "Phantom"
    assert_includes result, "signAndSendTransaction"
  end

  # --- journal versioning --------------------------------------------------

  def test_a_journal_from_another_release_is_refused_loudly
    # THE CROSS-REPO GUARD. This surface spans three repos with a gem floor
    # between them. An old callback meeting a new journal must fail by NAME
    # rather than derive a wrong shared secret and surface the damage somewhere
    # unrelated.
    result = run_js(<<~JS)
      try {
        R.forWallet('phantom').completeConnect({ data: 'd', nonce: 'n' }, { v: 99, step: 'connect' });
        return 'accepted';
      } catch (e) { return e.message; }
    JS
    assert_includes result, "version 99"
    assert_includes result, "different release"
  end

  def test_a_journal_at_the_wrong_step_is_refused
    result = run_js(<<~JS)
      try {
        R.forWallet('phantom').completeConnect({ data: 'd', nonce: 'n' }, { v: 1, step: 'signMessage' });
        return 'accepted';
      } catch (e) { return e.message; }
    JS
    assert_includes result, "step signMessage"
  end

  # --- error redirects -----------------------------------------------------

  def test_user_rejection_is_read_before_any_decryption_is_attempted
    # An error redirect carries NO data and NO nonce. A decrypt-first reader
    # turns a clean rejection into a decryption exception — the class of
    # miscategorisation that shows balance advice to someone who attempted no
    # transaction. Asserted on all three, since the error table is shared.
    result = run_js(<<~JS)
      return R.all().map(function(p) {
        try {
          p.completeConnect({ errorCode: '4001', errorMessage: 'User rejected' }, { v: 1, step: 'connect' });
          return 'no-throw';
        } catch (e) { return [e.rejected, e.code, e.message]; }
      });
    JS
    result.each { |r| assert_equal [true, "4001", "User rejected"], r }
  end

  def test_a_non_rejection_error_is_not_reported_as_a_rejection
    result = run_js(<<~JS)
      try {
        R.forWallet('solflare').completeConnect({ errorCode: '-32603', errorMessage: 'Internal' }, { v: 1, step: 'connect' });
        return 'no-throw';
      } catch (e) { return [e.rejected, e.code]; }
    JS
    assert_equal [false, "-32603"], result
  end

  # --- real crypto round trips --------------------------------------------

  def test_connect_round_trips_against_a_real_wallet_side_keypair
    # Drives the FULL handshake with real tweetnacl on both sides: the provider
    # builds a connect URL, a simulated wallet derives the same shared secret
    # from the dapp key it was handed, encrypts a response, and the provider
    # decrypts it. A wrong key, a swapped nonce or a bad base58 hop all fail here
    # and nowhere else.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      var p = R.forWallet('phantom');
      var begun = p.beginConnect({ appUrl: 'https://a.test', redirectLink: 'https://a.test/cb', cluster: 'devnet' });

      // The wallet side: its own keypair, the shared secret from OUR public key.
      var walletPair = nacl.box.keyPair();
      var shared = nacl.box.before(T.base58.decode(begun.journal.dappPublicKey), walletPair.secretKey);
      var nonce = nacl.randomBytes(24);
      var body = new TextEncoder().encode(JSON.stringify({ public_key: 'USERPUBKEY', session: 'SESSION-TOKEN' }));
      var sealed = nacl.box.after(body, nonce, shared);

      var done = p.completeConnect({
        phantom_encryption_public_key: T.base58.encode(walletPair.publicKey),
        nonce: T.base58.encode(nonce),
        data: T.base58.encode(sealed)
      }, begun.journal);

      return {
        url: begun.url.indexOf('https://phantom.app/ul/v1/connect?') === 0,
        publicKey: done.publicKey,
        session: done.session,
        step: done.journal.step,
        keptWalletKey: done.journal.walletPublicKey === T.base58.encode(walletPair.publicKey)
      };
    JS
    assert_equal true, result["url"]
    assert_equal "USERPUBKEY", result["publicKey"]
    assert_equal "SESSION-TOKEN", result["session"]
    assert_equal "connected", result["step"]
    assert_equal true, result["keptWalletKey"], "the journal must keep the wallet key so the secret can be re-derived"
  end

  def test_signing_seals_the_session_and_survives_a_simulated_page_death
    # THE POINT OF THE WHOLE DESIGN: the journal is round-tripped through JSON
    # between begin and complete, which is what actually happens when the page is
    # destroyed. Anything the provider kept in a closure would be gone here.
    # Driven on Solflare and Backpack for signAndSend, and on Phantom for
    # signTransaction, because that is the split the deprecation forces.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      function connected(p) {
        var begun = p.beginConnect({ appUrl: 'https://a.test', redirectLink: 'https://a.test/cb' });
        var walletPair = nacl.box.keyPair();
        var shared = nacl.box.before(T.base58.decode(begun.journal.dappPublicKey), walletPair.secretKey);
        var nonce = nacl.randomBytes(24);
        var body = new TextEncoder().encode(JSON.stringify({ public_key: 'PK', session: 'SESS' }));
        var done = p.completeConnect({
          phantom_encryption_public_key: T.base58.encode(walletPair.publicKey),
          wallet_encryption_public_key: T.base58.encode(walletPair.publicKey),
          solflare_encryption_public_key: T.base58.encode(walletPair.publicKey),
          nonce: T.base58.encode(nonce),
          data: T.base58.encode(nacl.box.after(body, nonce, shared))
        }, begun.journal);
        return { journal: done.journal, walletPair: walletPair, shared: shared };
      }

      return ['phantom', 'solflare', 'backpack'].map(function(key) {
        var p = R.forWallet(key);
        var c = connected(p);
        // THE PAGE DIES HERE. Only JSON survives.
        var revived = JSON.parse(JSON.stringify(c.journal));

        var method = p.can('signAndSendTransaction') ? 'SignAndSendTransaction' : 'SignTransaction';
        var begun = p['begin' + method]({ journal: revived, transaction: 'TXB58', redirectLink: 'https://a.test/cb' });

        // Wallet side decrypts what we sealed, proving the session travelled.
        var url = new URL(begun.url);
        var sent = JSON.parse(new TextDecoder().decode(nacl.box.open.after(
          T.base58.decode(url.searchParams.get('payload')),
          T.base58.decode(url.searchParams.get('nonce')),
          c.shared
        )));

        // Wallet answers; provider decrypts through a JSON-revived journal again.
        var rn = nacl.randomBytes(24);
        var reply = new TextEncoder().encode(JSON.stringify({ signature: 'SIG-' + key }));
        var out = p['complete' + method](
          { nonce: T.base58.encode(rn), data: T.base58.encode(nacl.box.after(reply, rn, c.shared)) },
          JSON.parse(JSON.stringify(begun.journal))
        );

        return [key, method, sent.session, sent.transaction, out.signature];
      });
    JS
    assert_equal ["phantom", "SignTransaction", "SESS", "TXB58", "SIG-phantom"], result[0]
    assert_equal ["solflare", "SignAndSendTransaction", "SESS", "TXB58", "SIG-solflare"], result[1]
    assert_equal ["backpack", "SignAndSendTransaction", "SESS", "TXB58", "SIG-backpack"], result[2]
  end

  def test_a_tampered_payload_fails_closed
    # Decryption returning null must raise, not yield undefined into a caller
    # that would then treat garbage as a signature.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      var p = R.forWallet('phantom');
      var begun = p.beginConnect({ appUrl: 'https://a.test', redirectLink: 'https://a.test/cb' });
      var walletPair = nacl.box.keyPair();
      try {
        p.completeConnect({
          phantom_encryption_public_key: T.base58.encode(walletPair.publicKey),
          nonce: T.base58.encode(nacl.randomBytes(24)),
          data: T.base58.encode(nacl.randomBytes(64))
        }, begun.journal);
        return 'accepted';
      } catch (e) { return e.message; }
    JS
    assert_includes result, "Decryption failed"
  end

  def test_browse_handoff_is_available_on_every_wallet
    # The tier that needs no protocol work at all: hand the user into the
    # wallet's own in-app browser, where the injected provider already works.
    result = run_js("return R.all().map(function(p) { return p.browseUrl('https://x.test/p', 'https://a.test'); });")
    assert result[0].start_with?("https://phantom.app/ul/browse/"), result[0]
    assert result[1].start_with?("https://solflare.com/ul/v1/browse/"), result[1]
    assert result[2].start_with?("https://backpack.app/ul/v1/browse/"), result[2]
  end
end
