// SolanaStudio.network — cluster-mismatch validation for onchain actions.
//
// THE CONSTRAINT THAT SHAPES ALL OF THIS: a website cannot read which network a
// browser wallet is set to. Phantom does not expose it, and the Wallet Standard
// `chains` array advertises what a wallet SUPPORTS, not what it has selected.
// So there is no pre-flight check to write. You cannot ask the wallet where it
// is. You can only do two things:
//
//   1. ASSERT, at sign-in, and let the wallet contradict you. Handing the wallet
//      a SIWS `chainId` makes it compare that against its own selected network
//      and object. This is the one pre-emptive signal that exists, it costs a
//      signature the user is already making, and it fires once per session.
//
//   2. EXPLAIN, after a failure. When a wallet action fails in a way a cluster
//      mismatch would explain, say so — as a hint beside the real error, never
//      instead of it. A misclassification that HIDES the true error is a worse
//      bug than the one this file exists to fix.
//
// Deliberately not a blocker. In a `signTransaction` + app-side
// `sendRawTransaction` architecture the app's own RPC decides where the
// transaction lands, so a wrong-network wallet cannot misroute funds. What it
// does is make the wallet simulate against the wrong chain — a frightening
// approval sheet, a balance from a chain nobody is using, and an abandoned
// flow. That is a clarity problem, and clarity is what this ships.
(function() {
  "use strict";

  var W = window;
  W.SolanaStudio = W.SolanaStudio || {};

  var LABELS = {
    "mainnet-beta": "Mainnet",
    "devnet": "Devnet",
    "testnet": "Testnet",
    "localnet": "Localnet"
  };

  // Mirrors Solana::Network::WALLET_STANDARD_CHAINS. Note mainnet loses its
  // -beta suffix here — "solana:mainnet-beta" is not a chain any wallet knows.
  var WALLET_STANDARD_CHAINS = {
    "mainnet-beta": "solana:mainnet",
    "devnet": "solana:devnet",
    "testnet": "solana:testnet",
    "localnet": "solana:localnet"
  };

  var ENVIRONMENT_LABELS = {
    qa: "QA",
    production: "Production",
    development: "Development",
    test: "Test"
  };

  // --- Page facts ------------------------------------------------------------
  // The server is the authority on which cluster this app runs against; the
  // browser only reads it. Preferred form is one JSON blob written from
  // Solana::Network.describe. The discrete attributes are a fallback so a host
  // can adopt the guard before it changes its layout.
  function context() {
    var body = document.body;
    if (!body || !body.dataset) return blank();

    var described = null;
    if (body.dataset.solanaNetwork) {
      try { described = JSON.parse(body.dataset.solanaNetwork); } catch (e) { described = null; }
    }

    var cluster = (described && described.cluster) || body.dataset.solanaCluster || "";
    var environment = (described && described.environment) || body.dataset.appEnvironment || "";

    return {
      cluster: cluster,
      known: !!LABELS[cluster],
      label: (described && described.label) || LABELS[cluster] || "Unknown Network",
      environment: environment,
      environmentLabel: ENVIRONMENT_LABELS[environment] ||
        (environment ? environment.charAt(0).toUpperCase() + environment.slice(1) : "Unknown"),
      walletStandardChain: (described && described.wallet_standard_chain) ||
        WALLET_STANDARD_CHAINS[cluster] || null
    };
  }

  function blank() {
    return {
      cluster: "", known: false, label: "Unknown Network",
      environment: "", environmentLabel: "Unknown", walletStandardChain: null
    };
  }

  // --- 1. Assert at sign-in --------------------------------------------------
  // The value to put on a SIWS input's `chainId`. Returns null when this app's
  // cluster has no Wallet Standard name, in which case the field must be OMITTED
  // rather than sent empty — an unrecognized chainId reads to the wallet as a
  // mismatch against every network, so a blank one rejects everybody.
  function signInChainId() {
    return context().walletStandardChain;
  }

  // Apply the chainId to a SIWS input, non-destructively. A host that does not
  // want the assertion simply does not call this.
  function withSignInChainId(signInInput) {
    var chainId = signInChainId();
    if (!chainId) return signInInput;

    var out = {};
    for (var k in signInInput) {
      if (Object.prototype.hasOwnProperty.call(signInInput, k)) out[k] = signInInput[k];
    }
    out.chainId = chainId;
    return out;
  }

  // --- 2. Explain after a failure -------------------------------------------
  // Error shapes a cluster mismatch would explain, ranked by how much of the
  // message the mismatch actually accounts for.
  //
  // UNRELATED, AND CHECKED FIRST. A custom program error means the program RAN:
  // it was found, on a chain that has it, and it rejected the instruction on its
  // own terms. Whatever else the envelope says, a cluster mismatch cannot explain
  // that outcome.
  //
  // This precedence is the fix for a real inversion. "Transaction simulation
  // failed" is the WRAPPER Solana puts around every failed simulation, including
  // ordinary business rejections, so matching it as LIKELY classified
  //
  //   "Transaction simulation failed: Error processing Instruction 0:
  //    custom program error: 0x1770"
  //
  // — a plain "contest is full" — as a probable network problem at top
  // confidence. That sends a user to change their wallet's network over a full
  // contest: the exact wrong-thing-to-fix this feature exists to prevent, with the
  // feature's own voice behind it. Found in review by executing this file.
  // Every entry here must name a PROGRAM CODE — proof the program ran and chose
  // this outcome. "Error processing Instruction 0:" is deliberately NOT here: it
  // is Solana's generic InstructionError envelope, and it wraps the not-found
  // failures below just as readily as it wraps a business rejection. Putting it
  // here fixed the first inversion by creating its mirror image: a wrapper at this
  // precedence answered `unrelated` for
  //
  //   "Transaction simulation failed: Error processing Instruction 0:
  //    Attempt to load a program that does not exist"
  //
  // so explain() returned null and the modal never opened. Precedence, verified
  // against solana-sdk's transaction-error source: ProgramAccountNotFound,
  // AccountNotFound and BlockhashNotFound all render TOP-LEVEL — only
  // InstructionError carries the "Error processing Instruction {i}:" wrapper. So
  // the composed string above is DEFENSIVE rather than observed; our own captured
  // corpus has never wrapped a not-found. It costs nothing to order correctly and
  // the rule generalizes: a wrapper must never decide confidence. That was the
  // lesson of the first fix, and this list is where it has to hold.
  var PROGRAM_ERROR = [
    /custom program error/i,
    /\b0x1[0-9a-f]{3}\b/i,          // Anchor's 6000+ user error range, as hex
    /\bAnchorError\b/i
  ];

  // The generic instruction envelope, checked AFTER the not-found signals. On its
  // own — no program code, and nothing above matched — an instruction failed on
  // its own terms and there is no wrong-chain signal to explain it, so it demotes
  // an otherwise-POSSIBLE shrug to `unrelated` rather than deciding anything.
  var INSTRUCTION_ERROR = [
    /error processing instruction/i,
    /\bInstructionError\b/i
  ];

  // LIKELY — the wallet looked for our program or our blockhash on a chain that
  // does not have them. Each of these names a thing that WAS NOT FOUND, which is
  // what a wrong chain actually produces; none of them is a wrapper.
  var LIKELY = [
    /attempt to load a program that does not exist/i,
    /program that does not exist/i,
    /ProgramAccountNotFound/i,
    /unlikely to succeed/i,
    /blockhash not found/i,
    // TransactionError::AccountNotFound. The canonical "this account has no
    // balance on the chain being simulated against" — top-level, unwrapped, and
    // with no business-logic reading, which is what earns it a place here when
    // the Anchor account errors deliberately do not get one (an
    // AccountNotInitialized on a PDA is genuinely ambiguous: wrong network, or a
    // right-network account nobody initialized).
    /found no record of a prior credit/i,
    /\bAccountNotFound\b/i
  ];

  // POSSIBLE — genuinely ambiguous. Phantom collapses a failed simulation into
  // a bare "Unexpected error", and a user who bails at a scary approval sheet is
  // indistinguishable from one who changed their mind. Worth a hint; never worth
  // replacing the real message.
  var POSSIBLE = [
    /^unexpected error$/i,
    /^unexpected/i,
    /user rejected/i,
    /user declined/i,
    // The bare wrapper, with no program error to account for it. Genuinely
    // ambiguous — worth a hint, never worth top confidence.
    /transaction simulation failed/i
  ];

  function messageOf(err) {
    if (!err) return "";
    if (typeof err === "string") return err;
    return err.message || err.error || String(err);
  }

  // How much would a cluster mismatch explain this failure?
  //   "likely" | "possible" | "unrelated"
  //
  // Nothing here is proof. The wallet never tells us where it was, so this is
  // inference over error text, and it is calibrated to under-claim: an
  // insufficient-funds error stays an insufficient-funds error.
  function classify(err) {
    var msg = messageOf(err);
    if (!msg) return "unrelated";

    var i;
    // Precedence, not just membership: a program error is checked BEFORE the
    // LIKELY list, because the wrapper text can carry both.
    for (i = 0; i < PROGRAM_ERROR.length; i++) {
      if (PROGRAM_ERROR[i].test(msg)) return "unrelated";
    }
    for (i = 0; i < LIKELY.length; i++) {
      if (LIKELY[i].test(msg)) return "likely";
    }
    // AFTER the not-found signals, never before: the envelope wraps them too.
    for (i = 0; i < INSTRUCTION_ERROR.length; i++) {
      if (INSTRUCTION_ERROR[i].test(msg)) return "unrelated";
    }
    for (i = 0; i < POSSIBLE.length; i++) {
      if (POSSIBLE[i].test(msg)) return "possible";
    }
    return "unrelated";
  }

  function couldBeMismatch(err) {
    return classify(err) !== "unrelated";
  }

  // The props a mismatch explainer modal needs. Returns null when a mismatch
  // would not explain the failure, so `var hint = explain(err); if (hint) {...}`
  // is the whole integration.
  function explain(err, opts) {
    opts = opts || {};
    var confidence = classify(err);
    if (confidence === "unrelated") return null;

    var ctx = context();
    return {
      confidence: confidence,
      cluster: ctx.cluster,
      networkLabel: ctx.label,
      environment: ctx.environment,
      environmentLabel: ctx.environmentLabel,
      action: opts.action || "This transaction",
      originalMessage: messageOf(err),
      title: "Check your wallet's network",
      message: (opts.action || "This transaction") + " runs on " + ctx.label +
               ", because you're on " + ctx.environmentLabel + ". If your wallet " +
               "is set to a different network, it will warn you and show the " +
               "wrong balance."
    };
  }

  // --- The wrapper -----------------------------------------------------------
  // Put this around any onchain action. It does not gate the call — it cannot,
  // and pretending otherwise would be a lie in the shape of a safety feature.
  // It runs the action, and when the action fails in a mismatch-shaped way it
  // hands the host a hint to show beside the error.
  //
  //   SolanaStudio.network.guard(
  //     function() { return provider.signTransaction(tx); },
  //     { action: "Entering this contest", onHint: showNetworkHint }
  //   )
  //
  // The original rejection is always re-thrown, unchanged. Callers keep their
  // existing error handling exactly as written.
  function guard(fn, opts) {
    opts = opts || {};
    return Promise.resolve()
      .then(fn)
      .catch(function(err) {
        var hint = explain(err, opts);
        if (hint && typeof opts.onHint === "function") {
          try { opts.onHint(hint, err); } catch (e) { /* a broken hint must not eat the error */ }
        }
        throw err;
      });
  }

  W.SolanaStudio.network = {
    context: context,
    signInChainId: signInChainId,
    withSignInChainId: withSignInChainId,
    classify: classify,
    couldBeMismatch: couldBeMismatch,
    explain: explain,
    guard: guard,
    WALLET_STANDARD_CHAINS: WALLET_STANDARD_CHAINS
  };
})();
