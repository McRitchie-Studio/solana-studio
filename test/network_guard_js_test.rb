require_relative "test_helper"
require "json"
require "tempfile"

# The browser guard's classifier, exercised in a real JS engine.
#
# The classifier is inference over wallet error text, and the ORDER of its two
# rule lists is load-bearing: "transaction simulation failed" must reach the
# LIKELY list before the broad /^unexpected/ POSSIBLE rule can claim it. That is
# exactly the kind of ordering a refactor breaks silently, so it is asserted
# here rather than left to review.
#
# Node runs the file with a minimal window/document shim — the guard touches
# nothing else, which is itself part of its contract.
class NetworkGuardJsTest < Minitest::Test
  GUARD = File.expand_path("../app/assets/javascripts/solana_studio/network_guard.js", __dir__)

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  # Runs `script` with the guard loaded and a body dataset of `dataset`.
  # Returns whatever the script assigns to `RESULT`, parsed from JSON.
  def run_js(dataset, script)
    harness = <<~JS
      global.window = global;
      global.document = { body: { dataset: #{JSON.generate(dataset)} } };
      #{File.read(GUARD)}
      var RESULT = (function() { #{script} })();
      // The guard is promise-based, so a case may return either a value or a
      // pending promise. Resolve both through the same path.
      Promise.resolve(RESULT).then(function(v) { console.log(JSON.stringify(v)); });
    JS

    Tempfile.create(["guard", ".js"]) do |f|
      f.write(harness)
      f.flush
      out = IO.popen(["node", f.path], err: [:child, :out], &:read)
      raise "node failed: #{out}" unless $?.success?

      JSON.parse(out.strip)
    end
  end

  def setup
    # FAILS rather than skips. A skipped JS lane is lost coverage that reads as
    # green, and bin/release-check rejects a skipped file for the same reason —
    # node is a requirement of this suite, not a nice-to-have.
    assert self.class.node?, "node is required to run the browser-guard suite (install node)"
  end

  DEVNET_QA = { "solanaCluster" => "devnet", "appEnvironment" => "qa" }.freeze

  def test_context_reads_discrete_data_attributes
    ctx = run_js(DEVNET_QA, "return SolanaStudio.network.context();")

    assert_equal "devnet", ctx["cluster"]
    assert_equal "Devnet", ctx["label"]
    assert_equal "QA", ctx["environmentLabel"]
    assert_equal "solana:devnet", ctx["walletStandardChain"]
    assert_equal true, ctx["known"]
  end

  def test_context_prefers_the_described_json_blob
    dataset = {
      "solanaNetwork" => JSON.generate(
        cluster: "mainnet-beta", label: "Mainnet",
        environment: "production", wallet_standard_chain: "solana:mainnet"
      ),
      "solanaCluster" => "devnet",       # stale discrete attrs must lose
      "appEnvironment" => "qa"
    }
    ctx = run_js(dataset, "return SolanaStudio.network.context();")

    assert_equal "mainnet-beta", ctx["cluster"]
    assert_equal "solana:mainnet", ctx["walletStandardChain"]
    assert_equal "Production", ctx["environmentLabel"]
  end

  def test_context_survives_malformed_json
    dataset = { "solanaNetwork" => "{not json", "solanaCluster" => "devnet", "appEnvironment" => "qa" }
    ctx = run_js(dataset, "return SolanaStudio.network.context();")

    assert_equal "devnet", ctx["cluster"], "a corrupt blob must fall back, not throw"
  end

  def test_sign_in_chain_id_drops_the_beta_suffix
    id = run_js({ "solanaCluster" => "mainnet-beta", "appEnvironment" => "production" },
                "return SolanaStudio.network.signInChainId();")
    assert_equal "solana:mainnet", id
  end

  def test_sign_in_chain_id_is_null_for_an_unknown_cluster
    # Must be null so the caller OMITS chainId. An empty or bogus value reads to
    # the wallet as a mismatch against every network — it would reject everyone.
    id = run_js({ "solanaCluster" => "wat", "appEnvironment" => "qa" },
                "return SolanaStudio.network.signInChainId();")
    assert_nil id
  end

  def test_with_sign_in_chain_id_does_not_mutate_the_input
    result = run_js(DEVNET_QA, <<~JS)
      var input = { domain: "example.test", nonce: "abc" };
      var out = SolanaStudio.network.withSignInChainId(input);
      return { out: out, inputUntouched: input.chainId === undefined };
    JS

    assert_equal "solana:devnet", result["out"]["chainId"]
    assert_equal "example.test", result["out"]["domain"]
    assert_equal true, result["inputUntouched"]
  end

  def test_simulation_failures_classify_as_likely
    msgs = [
      "Transaction simulation failed: Attempt to load a program that does not exist",
      "ProgramAccountNotFound",
      "failed to send transaction: Blockhash not found"
    ]
    got = run_js(DEVNET_QA, "return #{JSON.generate(msgs)}.map(function(m) { return SolanaStudio.network.classify(m); });")

    assert_equal %w[likely likely likely], got
  end

  def test_ordering_puts_simulation_failure_in_likely_not_possible
    # The regression this guards: /^unexpected/ in POSSIBLE is broad, and a
    # reordering that let it run first would demote every simulation failure.
    assert_equal "likely",
                 run_js(DEVNET_QA, 'return SolanaStudio.network.classify("Unexpected error: Transaction simulation failed");')
  end

  def test_ambiguous_wallet_errors_classify_as_possible
    got = run_js(DEVNET_QA, <<~JS)
      return ["Unexpected error", "User rejected the request."]
        .map(function(m) { return SolanaStudio.network.classify(m); });
    JS

    assert_equal %w[possible possible], got
  end

  def test_unrelated_failures_stay_unrelated
    # The under-claim guarantee. An insufficient-funds error must never be
    # dressed up as a network problem — that sends the user to fix the wrong
    # thing, which is the exact bug this feature exists to remove.
    got = run_js(DEVNET_QA, <<~JS)
      return ["Insufficient USDC balance.", "Contest is full.", "0x1774", ""]
        .map(function(m) { return SolanaStudio.network.classify(m); });
    JS

    assert_equal %w[unrelated unrelated unrelated unrelated], got
  end

  def test_explain_returns_null_for_an_unrelated_error
    assert_nil run_js(DEVNET_QA, 'return SolanaStudio.network.explain("Insufficient USDC balance.");')
  end

  def test_explain_carries_the_original_message_verbatim
    hint = run_js(DEVNET_QA, <<~JS)
      return SolanaStudio.network.explain("Transaction simulation failed", { action: "Entering this contest" });
    JS

    assert_equal "likely", hint["confidence"]
    assert_equal "Devnet", hint["networkLabel"]
    assert_equal "QA", hint["environmentLabel"]
    assert_equal "Transaction simulation failed", hint["originalMessage"]
    assert_includes hint["message"], "Devnet"
    assert_includes hint["message"], "QA"
  end

  def test_explain_reads_an_error_object_not_just_a_string
    hint = run_js(DEVNET_QA, 'return SolanaStudio.network.explain(new Error("Blockhash not found"));')
    assert_equal "likely", hint["confidence"]
  end

  def test_guard_rethrows_the_original_error_after_hinting
    # The wrapper must be transparent. A guard that swallowed the rejection
    # would break every existing catch block at the call sites it wraps.
    result = run_js(DEVNET_QA, <<~JS)
      var seen = null;
      return SolanaStudio.network.guard(
        function() { return Promise.reject(new Error("Transaction simulation failed")); },
        { action: "Entering", onHint: function(h) { seen = h.confidence; } }
      ).then(
        function() { return { settled: "resolved" }; },
        function(err) { return { settled: "rejected", message: err.message, hint: seen }; }
      );
    JS

    assert_equal "rejected", result["settled"]
    assert_equal "Transaction simulation failed", result["message"]
    assert_equal "likely", result["hint"]
  end

  def test_guard_passes_a_success_through_untouched
    result = run_js(DEVNET_QA, <<~JS)
      var hinted = false;
      return SolanaStudio.network.guard(
        function() { return Promise.resolve("signature123"); },
        { onHint: function() { hinted = true; } }
      ).then(function(v) { return { value: v, hinted: hinted }; });
    JS

    assert_equal "signature123", result["value"]
    assert_equal false, result["hinted"]
  end

  def test_a_throwing_hint_callback_does_not_replace_the_real_error
    result = run_js(DEVNET_QA, <<~JS)
      return SolanaStudio.network.guard(
        function() { return Promise.reject(new Error("Blockhash not found")); },
        { onHint: function() { throw new Error("modal blew up"); } }
      ).catch(function(err) { return { message: err.message }; });
    JS

    assert_equal "Blockhash not found", result["message"]
  end

  def test_guard_does_not_hint_on_an_unrelated_failure
    result = run_js(DEVNET_QA, <<~JS)
      var hinted = false;
      return SolanaStudio.network.guard(
        function() { return Promise.reject(new Error("Insufficient USDC balance.")); },
        { onHint: function() { hinted = true; } }
      ).catch(function(err) { return { hinted: hinted, message: err.message }; });
    JS

    assert_equal false, result["hinted"]
    assert_equal "Insufficient USDC balance.", result["message"]
  end
end
