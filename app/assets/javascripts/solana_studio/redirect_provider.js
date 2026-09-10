// SolanaStudio.redirectProvider — the redirect transport's provider surface.
//
// ONE FACTORY, NOT THREE ADAPTERS, and that is a deliberate call worth defending
// rather than discovering later. Phantom, Solflare and Backpack all fork the
// same deeplink spec: identical request parameters, identical payload JSON keys,
// identical response keys, identical error codes, identical crypto. Every real
// divergence already lives as data in walletTransport.PROFILES. Three files
// would therefore be three copies of one algorithm differing by a lookup — and
// the copies drift, which is the failure this codebase has been bitten by
// before. So the behaviour is written once and PARAMETERISED by profile, and
// the per-wallet differences are pinned by per-wallet tests instead.
//
// WHAT A REDIRECT PROVIDER CANNOT BE. A promise. `await provider.connect()`
// works because the page survives the call; here the page is DESTROYED and the
// answer arrives on a callback URL in a fresh document. So every operation
// splits in two:
//
//   begin<Op>(opts)              → { url, journal }   — caller navigates + persists
//   complete<Op>(params, journal) → the result        — caller ran the callback
//
// This object performs NO navigation and touches NO storage. That is not
// squeamishness: it is what keeps the whole surface runnable in node, which is
// how the per-wallet differences are actually asserted rather than hoped for.
// The caller owns `window.location` and the journal's storage; the intent
// registry and the resume journal own when and where.
//
// THE JOURNAL IS VERSIONED FROM ITS FIRST COMMIT. An old callback meeting a new
// journal must fail loudly rather than decrypt garbage — this spans three repos
// with a gem floor between them, and the Gemfile records several rounds of
// silent failure from exactly that drift. JOURNAL_VERSION is the cheapest
// insurance in the design.
(function (W) {
  'use strict';

  W.SolanaStudio = W.SolanaStudio || {};

  var JOURNAL_VERSION = 1;

  function core() {
    var t = W.SolanaStudio && W.SolanaStudio.walletTransport;
    if (!t) throw new Error('SolanaStudio.redirectProvider requires solana_studio/wallet_transport.js');
    return t;
  }

  // The journal carries the DAPP's ephemeral secret key, base58. That is the
  // established shape (turf-monster's deep link already stores phantom_dl_secret
  // the same way) and it is worth stating why it is safe: this keypair is
  // generated per connect, exists only to decrypt the wallet's replies to THIS
  // app, and is not the user's wallet key. It cannot sign, spend, or authorise
  // anything. Losing it costs one reconnect.
  //
  // What must NEVER go in here is anything the wallet signs over or the user
  // owns — a transaction's bytes, a private key, a session the user did not
  // establish. The server-side prepared-transaction slug exists precisely so a
  // transaction never has to travel this way.
  function newJournal(walletKey, step, extra) {
    var j = {
      v: JOURNAL_VERSION,
      wallet: walletKey,
      step: step,
      startedAt: Date.now()
    };
    for (var k in extra) {
      if (Object.prototype.hasOwnProperty.call(extra, k)) j[k] = extra[k];
    }
    return j;
  }

  function requireJournal(journal, expectedStep) {
    if (!journal) throw new Error('No pending wallet request');
    if (journal.v !== JOURNAL_VERSION) {
      // NAMED, and refusing. A version we do not understand is not something to
      // best-effort our way through — the shared secret would decrypt to
      // nonsense and the failure would surface somewhere unrelated.
      throw new Error(
        'Wallet journal version ' + journal.v + ' is not supported (expected ' +
        JOURNAL_VERSION + ') — the wallet request was started by a different release'
      );
    }
    if (expectedStep && journal.step !== expectedStep) {
      throw new Error('Wallet journal is at step ' + journal.step + ', expected ' + expectedStep);
    }
    return journal;
  }

  // Every completion starts here. An error redirect carries NO data and NO
  // nonce, so a decrypt-first reader turns a clean user rejection into a
  // decryption exception — which is exactly the class of miscategorised failure
  // that puts balance advice in front of someone who attempted no transaction.
  function throwIfWalletError(params) {
    var err = core().errorFrom(params);
    if (!err) return;
    var e = new Error(err.message);
    e.code = err.code;
    e.rejected = err.rejected;
    throw e;
  }

  function readParam(params, name) {
    if (!params) return null;
    return typeof params.get === 'function' ? params.get(name) : params[name];
  }

  // Re-derive the shared secret from what the journal kept. This is what makes
  // resume possible at all: the secret itself is binary and never stored, only
  // the two base58 keys needed to recompute it.
  function sharedSecretFrom(journal) {
    var t = core();
    if (!journal.walletPublicKey) throw new Error('Wallet journal carries no wallet public key — connect first');
    return t.codec.sharedSecret(journal.walletPublicKey, t.base58.decode(journal.dappSecretKey));
  }

  function build(walletKey) {
    var t = core();
    var p = t.profile(walletKey);
    if (!p) throw new Error('Unknown wallet: ' + walletKey);

    // A signing request, built once for every method that takes one. The only
    // thing that varies between signMessage, signTransaction and
    // signAndSendTransaction is the payload's shape and the method name — the
    // envelope, the encryption and the journal are identical.
    function beginSigned(method, step, payloadFields, opts) {
      if (!t.can(walletKey, method)) {
        throw new Error(p.name + ' does not support ' + method + ' over the redirect transport');
      }
      var journal = requireJournal(opts.journal);
      var secret = sharedSecretFrom(journal);
      var payload = { session: journal.session };
      for (var k in payloadFields) {
        if (Object.prototype.hasOwnProperty.call(payloadFields, k)) payload[k] = payloadFields[k];
      }
      var sealed = t.codec.encrypt(payload, secret);
      return {
        url: t.url.method(walletKey, method, {
          dappPublicKey: journal.dappPublicKey,
          nonce: sealed.nonce,
          // The caller's value wins when present, but a resume has no caller —
          // it runs on a page the wallet sent us to. The journal is the fallback
          // that makes the second hop possible at all.
          redirectLink: opts.redirectLink || journal.redirectLink,
          payload: sealed.payload,
          useScheme: opts.useScheme
        }),
        journal: newJournal(walletKey, step, {
          dappSecretKey: journal.dappSecretKey,
          dappPublicKey: journal.dappPublicKey,
          walletPublicKey: journal.walletPublicKey,
          redirectLink: opts.redirectLink || journal.redirectLink,
          session: journal.session,
          intent: opts.intent || journal.intent || null
        })
      };
    }

    function completeSigned(step, params, journal) {
      throwIfWalletError(params);
      requireJournal(journal, step);
      var data = readParam(params, 'data');
      var nonce = readParam(params, 'nonce');
      if (!data || !nonce) throw new Error('Wallet redirect carried no payload');
      return t.codec.decrypt(data, nonce, sharedSecretFrom(journal));
    }

    return {
      name: p.name,
      key: walletKey,
      transport: 'redirect',
      // Exposed per-provider, not only on the module, so a caller holding just a
      // provider can stamp a journal it builds itself (the supplied-session path
      // in walletOps does exactly that).
      JOURNAL_VERSION: JOURNAL_VERSION,

      // The capability gate, per wallet. A caller asks BEFORE it paints a
      // button — asking after is how a null provider reached .connect().
      can: function (method) { return t.can(walletKey, method); },
      supportsCluster: function (cluster) { return t.supportsCluster(walletKey, cluster); },
      sendStrategy: function () { return t.sendStrategy(walletKey); },

      // --- connect ---------------------------------------------------------
      // Carries NO nonce and NO payload: the shared secret does not exist yet.
      // This is the one asymmetry in the protocol and the reason connect cannot
      // reuse beginSigned.
      beginConnect: function (opts) {
        var pair = t.codec.keypair();
        var dappPublicKey = t.base58.encode(pair.publicKey);
        return {
          url: t.url.connect(walletKey, {
            appUrl: opts.appUrl,
            dappPublicKey: dappPublicKey,
            redirectLink: opts.redirectLink,
            cluster: opts.cluster,
            useScheme: opts.useScheme
          }),
          // redirectLink IS TRIP STATE, not call state. The hop AFTER this one
          // runs in a different document — often reached by the wallet, not by
          // us — and it needs the same return address. Capturing only what the
          // next LINE uses is what lost it; the journal exists precisely for
          // what the whole trip needs.
          journal: newJournal(walletKey, 'connect', {
            dappSecretKey: t.base58.encode(pair.secretKey),
            dappPublicKey: dappPublicKey,
            redirectLink: opts.redirectLink,
            intent: opts.intent || null
          })
        };
      },

      completeConnect: function (params, journal) {
        throwIfWalletError(params);
        requireJournal(journal, 'connect');
        // The one response key that differs between wallets — resolved by the
        // core so Backpack's documented/placeholder ambiguity lives in one place.
        var walletPublicKey = t.connectPublicKey(walletKey, params);
        if (!walletPublicKey) {
          throw new Error(p.name + ' redirect carried no encryption public key');
        }
        var data = readParam(params, 'data');
        var nonce = readParam(params, 'nonce');
        if (!data || !nonce) throw new Error('Wallet redirect carried no payload');

        var secret = t.codec.sharedSecret(walletPublicKey, t.base58.decode(journal.dappSecretKey));
        var decoded = t.codec.decrypt(data, nonce, secret);

        return {
          publicKey: decoded.public_key,
          session: decoded.session,
          // The journal a caller persists to make later signing possible.
          journal: newJournal(walletKey, 'connected', {
            dappSecretKey: journal.dappSecretKey,
            dappPublicKey: journal.dappPublicKey,
            walletPublicKey: walletPublicKey,
            session: decoded.session,
            intent: journal.intent || null
          })
        };
      },

      // --- signMessage -----------------------------------------------------
      // Sign-in is connect THEN signMessage on every wallet — no vendor ships a
      // documented signIn deeplink, so there is no one-hop path to prefer here.
      beginSignMessage: function (opts) {
        return beginSigned('signMessage', 'signMessage', {
          message: opts.message,           // base58, per the protocol
          display: opts.display || 'utf8'
        }, opts);
      },
      completeSignMessage: function (params, journal) {
        return completeSigned('signMessage', params, journal);
      },

      // --- signTransaction -------------------------------------------------
      // The app broadcasts afterwards. On Phantom this is the ONLY path, because
      // its signAndSendTransaction deeplink is deprecated.
      beginSignTransaction: function (opts) {
        return beginSigned('signTransaction', 'signTransaction', {
          transaction: opts.transaction
        }, opts);
      },
      completeSignTransaction: function (params, journal) {
        return completeSigned('signTransaction', params, journal);
      },

      // --- signAndSendTransaction ------------------------------------------
      // The wallet broadcasts. Refused on Phantom by the capability gate, which
      // is the point: the deprecation is data, not a special case here.
      beginSignAndSendTransaction: function (opts) {
        return beginSigned('signAndSendTransaction', 'signAndSendTransaction', {
          transaction: opts.transaction,
          sendOptions: opts.sendOptions
        }, opts);
      },
      completeSignAndSendTransaction: function (params, journal) {
        return completeSigned('signAndSendTransaction', params, journal);
      },

      // --- browse ----------------------------------------------------------
      // The handoff that needs no protocol at all: open the page inside the
      // wallet's own in-app browser, where the INJECTED provider works and the
      // existing inline transport runs unchanged. Every wallet that ships this
      // gets a working mobile path even with no adapter behind it.
      browseUrl: function (targetUrl, refUrl) {
        return t.url.browse(walletKey, targetUrl, refUrl);
      }
    };
  }

  W.SolanaStudio.redirectProvider = {
    JOURNAL_VERSION: JOURNAL_VERSION,

    // Build a provider for one wallet. Returns null for a wallet with no
    // profile rather than throwing — callers enumerate.
    forWallet: function (walletKey) {
      var t = core();
      return t.profile(walletKey) ? build(String(walletKey).toLowerCase()) : null;
    },

    // Every wallet reachable over the redirect transport. This is what a picker
    // enumerates on a phone, and what `detect()` in a consuming app chooses from
    // when no provider is injected.
    all: function () {
      var t = core();
      var out = [];
      for (var k in t.PROFILES) {
        if (Object.prototype.hasOwnProperty.call(t.PROFILES, k)) out.push(build(k));
      }
      return out;
    }
  };
})(typeof window !== 'undefined' ? window : globalThis);
