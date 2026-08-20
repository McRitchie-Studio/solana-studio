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
  // LIKELY — the wallet simulated against a chain where our program or accounts
  // do not exist. These messages have essentially no other cause in a flow that
  // worked yesterday.
  var LIKELY = [
    /attempt to load a program that does not exist/i,
    /program that does not exist/i,
    /ProgramAccountNotFound/i,
    /transaction simulation failed/i,
    /unlikely to succeed/i,
    /blockhash not found/i
  ];

  // POSSIBLE — genuinely ambiguous. Phantom collapses a failed simulation into
  // a bare "Unexpected error", and a user who bails at a scary approval sheet is
  // indistinguishable from one who changed their mind. Worth a hint; never worth
  // replacing the real message.
  var POSSIBLE = [
    /^unexpected error$/i,
    /^unexpected/i,
    /user rejected/i,
    /user declined/i
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
    for (i = 0; i < LIKELY.length; i++) {
      if (LIKELY[i].test(msg)) return "likely";
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
