// SolanaStudio.walletOps — one call site, every platform.
//
// THE PROBLEM THIS SOLVES, and it is not "mobile support". It is that the SAME
// piece of product logic — enter a contest, rename a user, export a wallet — has
// to run over two transports with incompatible shapes: one where `await` works,
// and one where the page is destroyed mid-operation. Written per-call-site, that
// becomes two implementations of every flow, and the mobile one silently rots
// because nobody exercises it on a laptop.
//
// So a flow is declared ONCE, as an intent:
//
//   walletOps.define('contest_entry', {
//     prepare:  function (ctx) { ... return { transaction: <base58>, ...state }; },
//     complete: function (ctx, result, state) { ... }
//   });
//
//   walletOps.run('contest_entry', { contestId: 12 }, { provider: ... });
//
// THE ONE RULE A CALLER MUST FOLLOW: handlers are registered BY NAME at page
// load, not passed as closures. A closure is precisely what cannot survive the
// redirect — the page that held it no longer exists when the wallet answers. The
// name is the only thing that can be written down and looked up again. Every
// other constraint in this file follows from that one.
//
// AND THE CORRESPONDING RULE ON STATE: whatever `prepare` returns must be
// JSON-serialisable, because on the redirect transport it is literally
// serialised. This is why the entry flow's server-side prepared-transaction slug
// matters so much — a slug survives the trip; a Transaction object does not.
//
// WHAT THIS FILE DOES NOT DO: it does not broadcast. Signing and sending are
// different responsibilities with different failure modes, and the wallet that
// broadcasts differs per vendor (Phantom deprecated its send-side deeplink, so
// the app sends; Solflare and Backpack send for you). `complete` is told which
// happened and owns the RPC, exactly as the existing flows already do.
(function (W) {
  'use strict';

  W.SolanaStudio = W.SolanaStudio || {};

  var handlers = {};

  function studio() { return W.SolanaStudio; }

  function requireHandler(name) {
    var h = handlers[name];
    if (!h) {
      // NAMED, because the most likely cause is a real and specific bug: a
      // callback page that did not load the script defining this intent. The
      // resume then fails here, far from the define() that never ran, and a
      // generic "not found" sends the reader hunting the journal instead.
      throw new Error(
        'No wallet intent registered as "' + name + '" — the page handling this ' +
        'callback must load the same script that defined it'
      );
    }
    return h;
  }

  // Default navigation, injectable so the whole surface stays testable in node.
  function defaultNavigate(url) {
    W.location.href = url;
  }

  // --- inline transport ----------------------------------------------------
  //
  // The path that already worked: the provider is injected, promises resolve,
  // nothing is written down. Kept deliberately close to what the existing call
  // sites do, so adopting walletOps is not also a rewrite of the desktop flow.
  function runInline(name, ctx, opts) {
    var handler = requireHandler(name);
    var provider = opts.provider;

    return Promise.resolve(handler.prepare(ctx)).then(function (prepared) {
      return Promise.resolve(provider.connect()).then(function () {
        return provider.signTransaction(prepared.transaction);
      }).then(function (signed) {
        return handler.complete(ctx, {
          signedTransaction: signed,
          signature: null,
          sendStrategy: 'app-broadcasts'
        }, prepared);
      });
    });
  }

  // --- redirect transport --------------------------------------------------
  //
  // Two or three hops, each ending in the page's destruction. `run` gets as far
  // as the first navigation; `resume` picks up whatever the callback carries and
  // either navigates again or finishes.
  function runRedirect(name, ctx, opts) {
    var handler = requireHandler(name);
    var provider = opts.provider;
    var journalStore = studio().walletJournal;
    var navigate = opts.navigate || defaultNavigate;

    // REFUSE EARLY rather than strand the user in their wallet app. Without a
    // writable store there is nothing to resume from, and the trip would end in
    // a callback page that finds no pending request and can only apologise.
    if (!journalStore.writable()) {
      return Promise.reject(new Error(
        'This browser cannot store a pending wallet request — open this page in ' +
        'your wallet app instead'
      ));
    }

    return Promise.resolve(handler.prepare(ctx)).then(function (prepared) {
      var intent = { op: name, ctx: ctx, state: prepared };

      // Already connected? Go straight to signing. Otherwise connect first and
      // carry the intent through — sessions do not expire on any of the three
      // wallets, so this branch is taken once per user, not once per action.
      var existing = opts.session || null;
      var begun = existing
        ? beginSigning(provider, intent, existing, opts)
        : provider.beginConnect({
            appUrl: opts.appUrl,
            redirectLink: opts.redirectLink,
            cluster: opts.cluster,
            intent: intent
          });

      if (!journalStore.save(begun.journal)) {
        return Promise.reject(new Error('Could not record the pending wallet request'));
      }
      navigate(begun.url);
      // Nothing resolves here in a real browser — the page is gone. The value is
      // for tests and for a caller that wants to know a trip started.
      return { suspended: true, url: begun.url };
    });
  }

  function beginSigning(provider, intent, session, opts) {
    var connected = {
      v: provider.JOURNAL_VERSION,
      step: 'connected'
    };
    // A caller supplying its own session hands us the journal fields the connect
    // hop would have produced. Kept explicit rather than reconstructed, because
    // guessing them is how a shared secret ends up derived from the wrong key.
    for (var k in session) {
      if (Object.prototype.hasOwnProperty.call(session, k)) connected[k] = session[k];
    }
    connected.intent = intent;
    return signingHop(provider, connected, opts);
  }

  // Which signing method this wallet gets is a CAPABILITY QUESTION, not a
  // preference: Phantom's send-side deeplink is deprecated, so it signs and the
  // app broadcasts. Asking the provider keeps that fact in the profile table
  // where it is asserted, rather than branching on a wallet name here.
  function signingHop(provider, journal, opts) {
    var payload = {
      journal: journal,
      transaction: journal.intent.state.transaction,
      redirectLink: opts.redirectLink,
      intent: journal.intent
    };
    return provider.can('signAndSendTransaction')
      ? provider.beginSignAndSendTransaction(payload)
      : provider.beginSignTransaction(payload);
  }

  // Called by the callback page. Reads the pending journal, advances one step,
  // and either navigates again or hands back the finished result.
  //
  // `take()` rather than `peek()` — reading clears, so a reloaded or
  // double-fired callback cannot advance the same step twice.
  function resume(params, opts) {
    opts = opts || {};
    var journalStore = studio().walletJournal;
    var navigate = opts.navigate || defaultNavigate;

    var journal = journalStore.take();
    if (!journal) return Promise.resolve({ pending: false });

    var provider = opts.provider ||
      studio().redirectProvider.forWallet(journal.wallet);
    if (!provider) {
      return Promise.reject(new Error('No provider for wallet "' + journal.wallet + '"'));
    }

    try {
      if (journal.step === 'connect') {
        var connected = provider.completeConnect(params, journal);
        var intent = connected.journal.intent;

        // Connect with no intent behind it is a plain sign-in: hand the caller
        // the account and stop. Connect CARRYING an intent immediately takes the
        // next hop, which is what makes a transaction on a cold session two
        // navigations rather than two user-initiated attempts.
        if (!intent) {
          return Promise.resolve({ pending: true, done: true, connect: connected });
        }

        var next = signingHop(provider, connected.journal, {
          redirectLink: opts.redirectLink || journal.redirectLink
        });
        if (!journalStore.save(next.journal)) {
          return Promise.reject(new Error('Could not record the pending wallet request'));
        }
        navigate(next.url);
        return Promise.resolve({ pending: true, suspended: true, url: next.url });
      }

      if (journal.step === 'signTransaction' || journal.step === 'signAndSendTransaction') {
        // HANDLER FIRST, BEFORE ANY DECRYPTION. If the intent is not registered
        // on this page, no amount of successful decryption helps — and a crypto
        // error surfacing here would send the reader after the shared secret
        // when the real fault is a script the callback page did not load.
        var handler = requireHandler(journal.intent && journal.intent.op);

        var wallet = journal.step === 'signAndSendTransaction';
        var out = wallet
          ? provider.completeSignAndSendTransaction(params, journal)
          : provider.completeSignTransaction(params, journal);
        return Promise.resolve(handler.complete(journal.intent.ctx, {
          signature: out.signature || null,
          signedTransaction: out.transaction || null,
          sendStrategy: wallet ? 'wallet-broadcasts' : 'app-broadcasts'
        }, journal.intent.state)).then(function (value) {
          return { pending: true, done: true, value: value };
        });
      }

      return Promise.reject(new Error('Unknown wallet journal step: ' + journal.step));
    } catch (e) {
      return Promise.reject(e);
    }
  }

  W.SolanaStudio.walletOps = {
    define: function (name, handler) {
      if (!handler || typeof handler.prepare !== 'function' || typeof handler.complete !== 'function') {
        throw new Error('walletOps.define("' + name + '") needs both prepare and complete');
      }
      handlers[name] = handler;
    },

    defined: function (name) { return !!handlers[name]; },
    names: function () { return Object.keys(handlers); },

    // Test seam only. Production pages define once at load and never clear.
    reset: function () { handlers = {}; },

    // The single call site. Chooses the transport from the provider it is given,
    // so a view never asks what platform it is on.
    run: function (name, ctx, opts) {
      opts = opts || {};
      if (!opts.provider) {
        return Promise.reject(new Error('walletOps.run needs a provider'));
      }
      return opts.provider.transport === 'redirect'
        ? runRedirect(name, ctx, opts)
        : runInline(name, ctx, opts);
    },

    resume: resume
  };
})(typeof window !== 'undefined' ? window : globalThis);
