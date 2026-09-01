require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

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
      # SEPARATE STREAMS. The result below is JSON.parsed straight off stdout,
      # so folding stderr in (`err: [:child, :out]`) would let ANY node chatter
      # — an ExperimentalWarning, a deprecation notice, a stray console.error
      # in the guard — arrive as a JSON parse error in a test about wallet
      # error classification. The same merge in test/engine_test.rb's helper
      # blocked a release; this one had not fired yet.
      out, err, status = Open3.capture3("node", f.path)
      raise "node failed: #{err}" unless status.success?

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

  # The harness's own contract, asserted before anything that depends on it.
  # `run_js` parses the child's stdout as JSON, so stderr reaching stdout is a
  # parse error rather than a readable failure. Restore the merged capture and
  # this test raises JSON::ParserError on the "noise on stderr" line.
  def test_the_js_harness_keeps_stderr_out_of_the_parsed_result
    result = run_js(DEVNET_QA, <<~JS)
      console.error("noise on stderr");
      return SolanaStudio.network.context().cluster;
    JS

    assert_equal "devnet", result,
                 "stdout must reach JSON.parse alone — node's stderr must never " \
                 "become part of the parsed result"
  end

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

  def test_not_found_failures_classify_as_likely
    msgs = [
      "Transaction simulation failed: Attempt to load a program that does not exist",
      # The WRAPPED form — how Solana actually delivers it. Every message in this
      # list omitted the instruction envelope until review caught that the suite
      # therefore never exercised the real envelope at all.
      "Transaction simulation failed: Error processing Instruction 0: Attempt to load a program that does not exist",
      "ProgramAccountNotFound",
      "failed to send transaction: Blockhash not found"
    ]
    got = run_js(DEVNET_QA, "return #{JSON.generate(msgs)}.map(function(m) { return SolanaStudio.network.classify(m); });")

    assert_equal %w[likely likely likely likely], got
  end

  def test_a_not_found_program_outranks_the_broad_unexpected_rule
    # /^unexpected/ in POSSIBLE is broad, and a reordering that let it run first
    # would demote a real wrong-chain signal to a shrug.
    assert_equal "likely",
                 run_js(DEVNET_QA,
                        'return SolanaStudio.network.classify("Unexpected error: Attempt to load a program that does not exist");')
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
    #
    # THE ENVELOPES ARE REAL. An earlier version of this test asserted the bare
    # string "0x1774", which no wallet ever emits — green, honest, and testing a
    # message nobody sends. A program error arrives WRAPPED, and the wrapper is
    # the whole difficulty (see the ordering test below).
    got = run_js(DEVNET_QA, <<~JS)
      return [
        "Insufficient USDC balance.",
        "Transaction simulation failed: Error processing Instruction 0: custom program error: 0x1774",
        "AnchorError caused by account: vault. Error Code: ConstraintSeeds. Error Number: 2006.",
        ""
      ].map(function(m) { return SolanaStudio.network.classify(m); });
    JS

    assert_equal %w[unrelated unrelated unrelated unrelated], got
  end

  # THE INVERSION THIS GUARDS, found in review by executing the shipped file.
  #
  # "Transaction simulation failed" is the wrapper Solana puts around EVERY failed
  # simulation, ordinary business rejections included. While that wrapper was in
  # the LIKELY list, a plain "contest is full" classified as a probable network
  # problem at TOP confidence — telling a user to change their wallet's network
  # over a full contest, in this feature's own voice. Precedence fixes it: a
  # custom program error means the program RAN, on a chain that has it.
  # ONE VARIABLE AT A TIME. The first version of this test put
  # "Error processing Instruction 0:" in the business arm and left it OUT of the
  # wrong-chain arm, so the two differed in two ways at once and could not isolate
  # which rule drove either verdict. The wrong one did: the instruction envelope
  # was deciding, and every wrong-network string in this file omitted it, so 111
  # green tests never touched the case the feature exists for. Both arms now carry
  # the IDENTICAL envelope and differ only in the tail.
  def test_the_program_code_decides_not_the_envelope_around_it
    got = run_js(DEVNET_QA, <<~JS)
      var envelope = "Transaction simulation failed: Error processing Instruction 0: ";
      return {
        business:   SolanaStudio.network.classify(envelope + "custom program error: 0x1770"),
        wrongChain: SolanaStudio.network.classify(envelope + "Attempt to load a program that does not exist"),
        bareEnvelope: SolanaStudio.network.classify(envelope + "invalid account data for instruction"),
        bareWrapper: SolanaStudio.network.classify("Transaction simulation failed")
      };
    JS

    assert_equal "unrelated", got["business"],
                 "a program CODE means the program ran — a wrong chain cannot explain it"
    assert_equal "likely", got["wrongChain"],
                 "the SAME envelope around a NOT-FOUND program is still the real signal"
    assert_equal "unrelated", got["bareEnvelope"],
                 "an instruction error with no program code and no not-found signal explains itself"
    assert_equal "possible", got["bareWrapper"],
                 "the bare simulation wrapper is ambiguous — a hint, never top confidence"
  end

  # DEFENSIVE, and labelled as such rather than dressed up as observed.
  #
  # Verified against solana-sdk's transaction-error source: ProgramAccountNotFound
  # renders TOP-LEVEL — only InstructionError carries the "Error processing
  # Instruction {i}:" wrapper — and our own captured corpus has never wrapped a
  # not-found. So this composed string is a shape Solana is not known to emit, and
  # saying so is the point: the LAST two defects in this classifier were both
  # tests asserting messages nobody sends. It is kept because ordering correctly
  # costs nothing and the rule it pins is general (a wrapper must never decide
  # confidence), not because it reproduces a field failure.
  def test_defensive_a_wrapped_not_found_is_still_not_silenced
    wrapped = "Transaction simulation failed: Error processing Instruction 0: " \
              "Attempt to load a program that does not exist"
    hint = run_js(DEVNET_QA, "return SolanaStudio.network.explain(#{wrapped.inspect});")

    refute_nil hint, "an envelope must never silence a not-found signal it merely wraps"
    assert_equal "likely", hint["confidence"]
  end

  # OBSERVED, by contrast — this one is a real string with a real taxonomy behind
  # it. TransactionError::AccountNotFound is the canonical "this account has no
  # balance on the chain being simulated against": top-level, unwrapped, and with
  # no business-logic reading. It classified `unrelated` until review found it.
  def test_account_not_found_is_a_wrong_network_signal
    got = run_js(DEVNET_QA, <<~JS)
      return ["Attempt to debit an account but found no record of a prior credit.",
              "AccountNotFound"].map(function(m) { return SolanaStudio.network.classify(m); });
    JS

    assert_equal %w[likely likely], got
  end

  # …and the deliberate NON-membership beside it, so the line between them is
  # asserted rather than implied. An Anchor account error is genuinely ambiguous —
  # wrong network, OR a right-network account nobody initialized — and turf-monster's
  # own ErrorInterpreter already reads that case as admin-actionable. Under-claiming
  # here is the design, not a gap.
  def test_anchor_account_errors_stay_unrelated_because_they_are_ambiguous
    got = run_js(DEVNET_QA, <<~JS)
      return ["Transaction simulation failed: Error processing Instruction 0: custom program error: 0xbc4",
              "AnchorError caused by account: contest. Error Code: AccountNotInitialized. Error Number: 3012."]
        .map(function(m) { return SolanaStudio.network.classify(m); });
    JS

    assert_equal %w[unrelated unrelated], got
  end

  def test_explain_returns_null_for_an_unrelated_error
    assert_nil run_js(DEVNET_QA, 'return SolanaStudio.network.explain("Insufficient USDC balance.");')
  end

  def test_explain_carries_the_original_message_verbatim
    hint = run_js(DEVNET_QA, <<~JS)
      return SolanaStudio.network.explain(
        "Transaction simulation failed: Attempt to load a program that does not exist",
        { action: "Entering this contest" });
    JS

    assert_equal "likely", hint["confidence"]
    assert_equal "Devnet", hint["networkLabel"]
    assert_equal "QA", hint["environmentLabel"]
    assert_equal "Transaction simulation failed: Attempt to load a program that does not exist",
                 hint["originalMessage"]
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
        function() { return Promise.reject(new Error("Transaction simulation failed: Attempt to load a program that does not exist")); },
        { action: "Entering", onHint: function(h) { seen = h.confidence; } }
      ).then(
        function() { return { settled: "resolved" }; },
        function(err) { return { settled: "rejected", message: err.message, hint: seen }; }
      );
    JS

    assert_equal "rejected", result["settled"]
    assert_equal "Transaction simulation failed: Attempt to load a program that does not exist", result["message"]
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
