require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

# The redirect transport's shared core, exercised in a real JS engine.
#
# WHAT THIS FILE IS DEFENDING. The three wallet protocols are ~95% identical, and
# that similarity is a trap: the natural refactor is to collapse the profile
# table into one entry plus a host string, and four of the divergences below
# would vanish silently if anyone did. Each test names the divergence it pins and
# what breaks without it. None of them is stylistic.
#
# Node runs the REAL shipped file with a minimal window shim — the core touches
# nothing else, which is itself part of its contract and is why it can be tested
# here at all rather than only in a browser.
class WalletTransportJsTest < Minitest::Test
  CORE = File.expand_path("../app/assets/javascripts/solana_studio/wallet_transport.js", __dir__)

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  # Runs `script` with the core loaded, returning whatever it produces as JSON.
  # `nacl:` injects a stand-in only for the tests that need the dependency to be
  # PRESENT; the default absence is itself under test.
  def run_js(script, nacl: false)
    harness = <<~JS
      global.window = global;
      #{nacl ? "global.nacl = { box: {}, randomBytes: function(n) { return new Uint8Array(n); } };" : ""}
      #{File.read(CORE)}
      var T = window.SolanaStudio.walletTransport;
      var RESULT = (function() { #{script} })();
      console.log(JSON.stringify(RESULT));
    JS

    Tempfile.create(["wallet_transport", ".js"]) do |f|
      f.write(harness)
      f.flush
      # SEPARATE STREAMS, for the reason network_guard_js_test.rb records: folding
      # stderr into stdout lets any node chatter arrive as a JSON parse error in a
      # test about wallet protocols. That merge blocked a release once already.
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      JSON.parse(out)
    end
  end

  def setup
    skip "node not available" unless self.class.node?
  end

  # --- base58 --------------------------------------------------------------

  def test_base58_round_trips_including_leading_zeros
    # Leading zero bytes are the classic base58 bug: they encode as '1' rather
    # than positionally, so a naive implementation loses them and every key with
    # a zero prefix decodes short.
    result = run_js(<<~JS)
      var cases = [[0,0,1,2,3], [255,254,253], [0], [1], []];
      return cases.map(function(c) {
        var round = Array.from(T.base58.decode(T.base58.encode(new Uint8Array(c))));
        return JSON.stringify(round) === JSON.stringify(c);
      });
    JS
    assert_equal [true] * 5, result, "base58 must round-trip, leading zeros included"
  end

  def test_base58_decode_refuses_an_invalid_character
    # '0' and 'O' are deliberately absent from the alphabet. Accepting them
    # silently would decode a typo'd key into plausible-looking wrong bytes.
    result = run_js("try { T.base58.decode('0OIl'); return 'accepted'; } catch (e) { return 'refused'; }")
    assert_equal "refused", result
  end

  # --- the per-wallet divergences ------------------------------------------

  def test_phantom_scheme_omits_ul_segment_and_solflare_keeps_it
    # THE TRAP THIS PINS: a "just swap the host" adapter. Phantom's custom scheme
    # is phantom://v1/<method>; Solflare's is solflare://ul/<v1>/<method>. One
    # shared template cannot express both, and the wrong one silently fails to
    # open the app at all.
    result = run_js(<<~JS)
      return {
        phantom: T.url.connect('phantom', { useScheme: true, appUrl: 'https://a.test', dappPublicKey: 'K', redirectLink: 'https://a.test/cb' }),
        solflare: T.url.connect('solflare', { useScheme: true, appUrl: 'https://a.test', dappPublicKey: 'K', redirectLink: 'https://a.test/cb' })
      };
    JS
    assert result["phantom"].start_with?("phantom://v1/connect?"), "got #{result['phantom']}"
    assert result["solflare"].start_with?("solflare://ul/v1/connect?"), "got #{result['solflare']}"
  end

  def test_backpack_has_no_scheme_and_falls_back_to_universal_link
    # Backpack documents no custom scheme at all. A caller may still ASK for one;
    # returning the universal link is correct, and refusing would strand a caller
    # that has a working link available.
    result = run_js("return T.url.connect('backpack', { useScheme: true, appUrl: 'https://a.test', dappPublicKey: 'K', redirectLink: 'https://a.test/cb' });")
    assert result.start_with?("https://backpack.app/ul/v1/connect?"), "got #{result}"
  end

  def test_phantom_browse_carries_no_version_segment
    # Phantom's browse is /ul/browse/ while its provider methods are /ul/v1/ —
    # a difference inside ONE wallet, which is why browsePath is a field rather
    # than a derivation.
    result = run_js(<<~JS)
      return {
        phantom: T.url.browse('phantom', 'https://x.test/p', 'https://a.test'),
        solflare: T.url.browse('solflare', 'https://x.test/p', 'https://a.test')
      };
    JS
    assert_includes result["phantom"], "/ul/browse/"
    refute_includes result["phantom"], "/ul/v1/browse/"
    assert_includes result["solflare"], "/ul/v1/browse/"
  end

  def test_phantom_refuses_sign_and_send_while_the_others_allow_it
    # Phantom DEPRECATED signAndSendTransaction. Treating all three alike here is
    # the mistake that would send Phantom users at a dead endpoint, and it is the
    # single most consequential divergence in the table.
    result = run_js(<<~JS)
      return {
        phantom: T.can('phantom', 'signAndSendTransaction'),
        solflare: T.can('solflare', 'signAndSendTransaction'),
        backpack: T.can('backpack', 'signAndSendTransaction'),
        phantomSend: T.sendStrategy('phantom'),
        solflareSend: T.sendStrategy('solflare')
      };
    JS
    assert_equal false, result["phantom"]
    assert_equal true, result["solflare"]
    assert_equal true, result["backpack"]
    assert_equal "app-broadcasts", result["phantomSend"]
    assert_equal "wallet-broadcasts", result["solflareSend"]
  end

  def test_url_method_refuses_an_unsupported_method_by_name
    # The refusal must name the wallet and the method — a generic throw here
    # reads as a bug in the core rather than as the deprecation it actually is.
    result = run_js("try { T.url.method('phantom', 'signAndSendTransaction', {}); return 'built'; } catch (e) { return e.message; }")
    assert_includes result, "phantom"
    assert_includes result, "signAndSendTransaction"
  end

  def test_no_wallet_advertises_a_signin_deeplink
    # Measured, not assumed: Phantom's signIn 404s in its docs and exists only in
    # its demo app; Solflare and Backpack have none. If a vendor ever ships one,
    # this test should fail and be updated deliberately.
    result = run_js("return ['phantom','solflare','backpack'].map(function(w) { return T.can(w, 'signIn'); });")
    assert_equal [false, false, false], result
  end

  def test_connect_public_key_resolves_per_wallet_with_backpack_fallback
    # The ONLY response key that differs between wallets. Backpack's own docs
    # disagree with themselves (wallet_encryption_public_key vs the wallet_xxx
    # placeholder), so both are tried in documented-first order.
    result = run_js(<<~JS)
      return {
        phantom: T.connectPublicKey('phantom', { phantom_encryption_public_key: 'PK' }),
        solflare: T.connectPublicKey('solflare', { solflare_encryption_public_key: 'SK' }),
        backpackDocumented: T.connectPublicKey('backpack', { wallet_encryption_public_key: 'BK' }),
        backpackPlaceholder: T.connectPublicKey('backpack', { wallet_xxx: 'BX' }),
        crossed: T.connectPublicKey('phantom', { solflare_encryption_public_key: 'SK' })
      };
    JS
    assert_equal "PK", result["phantom"]
    assert_equal "SK", result["solflare"]
    assert_equal "BK", result["backpackDocumented"]
    assert_equal "BX", result["backpackPlaceholder"]
    assert_nil result["crossed"], "a wallet must not read another wallet's key"
  end

  def test_backpack_does_not_support_devnet
    # Backpack documents no devnet. Consumers testing on devnet cannot QA that
    # adapter, and the honest answer here is what surfaces that decision rather
    # than letting a devnet session fail opaquely on a real phone.
    result = run_js(<<~JS)
      return {
        backpackDevnet: T.supportsCluster('backpack', 'devnet'),
        phantomDevnet: T.supportsCluster('phantom', 'devnet'),
        backpackMainnet: T.supportsCluster('backpack', 'mainnet-beta')
      };
    JS
    assert_equal false, result["backpackDevnet"]
    assert_equal true, result["phantomDevnet"]
    assert_equal true, result["backpackMainnet"]
  end

  # --- error redirects -----------------------------------------------------

  def test_error_from_flags_user_rejection_and_ignores_a_clean_redirect
    # Error redirects carry NO data and NO nonce, so this must be readable
    # BEFORE any decryption is attempted — a decrypt-first reader turns a clean
    # user rejection into a decryption exception.
    result = run_js(<<~JS)
      return {
        rejected: T.errorFrom({ errorCode: '4001', errorMessage: 'User rejected' }),
        other: T.errorFrom({ errorCode: '-32603', errorMessage: 'Internal' }),
        clean: T.errorFrom({ data: 'x', nonce: 'y' })
      };
    JS
    assert_equal true, result["rejected"]["rejected"]
    assert_equal false, result["other"]["rejected"]
    assert_equal "-32603", result["other"]["code"]
    assert_nil result["clean"], "a successful redirect carries no error"
  end

  # --- the guarded dependency ----------------------------------------------

  def test_codec_names_its_missing_dependency
    # A bare TypeError on `nacl.box` would send a reader hunting the codec. The
    # whole point of a guarded dependency is that its absence reads as itself.
    result = run_js("try { T.codec.keypair(); return 'built'; } catch (e) { return e.message; }")
    assert_includes result, "tweetnacl"
  end

  def test_profile_and_capability_answer_no_for_an_unknown_wallet
    # A caller asking about a wallet we have never heard of wants "no", not an
    # exception — the capability gate is called during render.
    result = run_js(<<~JS)
      return {
        profile: T.profile('nonesuch'),
        can: T.can('nonesuch', 'connect'),
        send: T.sendStrategy('nonesuch')
      };
    JS
    assert_nil result["profile"]
    assert_equal false, result["can"]
    assert_nil result["send"]
  end
end
