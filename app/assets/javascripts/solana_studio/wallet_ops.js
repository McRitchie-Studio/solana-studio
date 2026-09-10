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
//     complete: function (ctx, result, state) { ... },
//     signOnly: true
//   });
//
//   walletOps.run('contest_entry', { contestId: 12 }, {
//     provider: ...,
//     expectedAccount: '<the address this account is linked to>',  // optional
//     owner: currentUser.id                                        // optional
//   });
//
// ONE HOP FOR A RETURNING USER — WHAT `owner` BUYS. Sessions never expire on
// Phantom, Solflare or Backpack (all three vendors' docs, verified 2026-09-07,
// recorded per wallet as `sessionsExpire: false` in wallet_transport.js's
// PROFILES table, each with the doc URL it came from). Nothing persisted one, so
// every mobile signing trip paid TWO app switches — connect, then sign — and the
// second one is where a real user's entry was lost on QA. Declare an `owner` and
// the connect hop's session is remembered, scoped to that user, that wallet and
// that cluster; the next trip skips straight to signing. Omit it and every trip
// behaves exactly as it did before, journal bytes included.
//
// The session lives in SolanaStudio.walletSession (wallet_journal.js), which
// documents its own lifetime and the four things that invalidate it. One of them
// is this file's to handle and is handled below: a wallet that refuses a stored
// session mid-trip recovers through a connect hop rather than losing the user's
// work (recoverThroughConnect).
//
// ⚠ ANOTHER IS THE HOST'S AND IS NOT WIRED UP TODAY. A logout must call
// walletJournal.purge(), which sweeps the session with the journal — and no
// consumer does: turf-monster sweeps the older `phantom_dl_` prefix, which does
// not match this subsystem's `wallet_dl_`. Passing `owner` without adding that
// call leaves a never-expiring session, and the dapp secret key beside it,
// alive across a logout on a shared device. Adopt them together.
//
// `signOnly` IS A REQUIREMENT OF THE TRANSACTION, NOT A PREFERENCE ABOUT THE
// WALLET, and it is the intent's to declare because only the intent knows the
// shape of the bytes it prepared. A CO-SIGNED transaction — one whose second
// signer slot is deliberately empty because a server fills it — cannot be
// broadcast by the wallet: the chain would reject it for a missing required
// signature, and, worse, the signed bytes the server needs would never come
// back to the app, so the flow fails with nothing to retry. Declaring it makes
// the transaction's own requirement outrank the wallet's capability. Omit it
// and nothing changes: a wallet that can broadcast still does.
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
// THE TRANSACTION IS WIRE BYTES ON EVERY TRANSPORT, AND THAT IS NOW ENFORCED.
// The rule above always implied it — base58 survives a page death and a
// `solanaWeb3.Transaction` does not — but only the redirect path obeyed it. The
// inline path passed `prepared.transaction` STRAIGHT to `provider.signTransaction`,
// which for an injected wallet must be a Transaction OBJECT, so a single intent
// could not serve both transports and every consumer kept a second call site for
// the desktop path. That is the duplication this file exists to prevent.
//
// One `prepare` cannot return both shapes, and this gem cannot convert between
// them: deserializing base58 into a Transaction needs @solana/web3.js, and the
// only JS dependency here is a GUARDED `window.nacl`. Taking web3.js would put a
// ~200KB browser library on the critical path of a gem whose other consumers are
// plain-Ruby, to do work the consumer's own wallet adapter already does.
//
// So the conversion is the INLINE PROVIDER'S, declared as a two-method codec:
//
//   provider.deserializeTransaction(base58)  → whatever signTransaction() takes
//   provider.serializeTransaction(signed)    → base58 wire bytes
//
// It belongs on the provider because the shape requirement is the PROVIDER'S,
// not the flow's — the same reason `can('signAndSendTransaction')` is answered
// there rather than branched on here. One adapter per app serves every intent;
// a per-intent hook would be the same three lines of web3.js copied into each
// flow, which is per-call-site duplication wearing a different hat. Both halves
// are REQUIRED and refused BY NAME, because the alternative failure is a base58
// string reaching an extension's signTransaction and throwing
// `t.serialize is not a function` from inside someone else's code.
//
// BOTH DIRECTIONS, and the return leg is not optional garnish: without
// `serializeTransaction` the redirect path hands `complete` a base58 string and
// the inline path hands it a signed Transaction object, so the call site
// branches anyway and nothing has been unified.
//
// EXPECTED ACCOUNT — A UX GUARD, NOT A SECURITY ONE, and worth saying plainly
// because the opposite claim is easy to make. `run(..., { expectedAccount })`
// declares which address the caller believes it is about to use; walletOps
// refuses the trip when a different one connects. THE OWNERSHIP PROOF IS
// ON-CHAIN — Anchor rejects a transaction whose signer does not match the PDA
// owner, with or without this — so what the declaration buys is a sentence a
// user can act on instead of a program error, and, on the inline transport, a
// server-minted prepared transaction that is never wasted. It rides in the
// journal as a STRING for the same reason `signOnly` does: it is the only kind
// of thing that survives the redirect.
//
// WHAT THIS FILE DOES NOT DO: it does not broadcast. Signing and sending are
// different responsibilities with different failure modes, and the wallet that
// broadcasts differs per vendor (Phantom deprecated its send-side deeplink, so
// the app sends; Solflare and Backpack send for you) — and, where the intent
// declares `signOnly`, per TRANSACTION as well. `complete` is told which
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

  // --- the transaction contract --------------------------------------------
  //
  // ONE SHAPE ON EVERY TRANSPORT: base58 wire bytes. Checked HERE, in the one
  // place both transports pass through, rather than at each of the two sites
  // that consume it — a contract enforced on one path only is how the inline
  // path drifted into taking a Transaction object in the first place.
  //
  // A MISSING transaction is refused alongside a wrongly-typed one. Every hop
  // this file can take is a transaction hop (`signingHop` reaches only
  // signTransaction and signAndSendTransaction), so an intent with nothing to
  // sign has no path through here — it would reach the wallet as
  // `transaction=undefined` and come back as that wallet's own words about an
  // invalid payload, one page death away from the handler that caused it.
  function requireWireTransaction(name, prepared) {
    var tx = prepared && prepared.transaction;
    if (typeof tx === 'string' && tx !== '') return prepared;
    // An EMPTY string is called out separately rather than reported as "a
    // string", because that message would send the reader looking for a type
    // error in a handler whose type is already right — the fault is a prepare
    // that came back with nothing to sign, usually a server field read under
    // the wrong name.
    var got = (tx === undefined || tx === null) ? 'no'
            : (tx === '') ? 'an empty'
            : ('a ' + typeof tx);
    throw new Error(
      'walletOps intent "' + name + '" prepared ' + got + ' transaction — ' +
      'prepare() must return { transaction: "<base58 wire bytes>", ...state } ' +
      'on EVERY transport. A Transaction object cannot be written to the ' +
      'journal, so it cannot survive a redirect.'
    );
  }

  // The inline transport's two-way conversion, which is the PROVIDER's because
  // the shape requirement is the provider's. Checked BEFORE the wallet is
  // touched, and both halves together: serializeTransaction is not reached
  // until after the user has approved a signature, and discovering it missing
  // there costs a real signing prompt and strands signed bytes nothing can post.
  var INLINE_CODEC = ['deserializeTransaction', 'serializeTransaction'];

  function requireInlineCodec(provider) {
    for (var i = 0; i < INLINE_CODEC.length; i++) {
      if (typeof provider[INLINE_CODEC[i]] !== 'function') {
        throw new Error(
          'The inline wallet provider has no ' + INLINE_CODEC[i] + '(). ' +
          'walletOps hands every transport the same base58 wire bytes, and an ' +
          'injected wallet signs a Transaction object, so the provider adapter ' +
          'owns both conversions — this gem cannot, without taking a ' +
          '@solana/web3.js dependency. See "The inline provider\'s transaction ' +
          'codec" in the solana-studio README.'
        );
      }
    }
  }

  // --- the expected account ------------------------------------------------
  //
  // A DECLARED VALUE RATHER THAN A CALLBACK, and the reason is the same one
  // that put `signOnly` in the journal: the connect callback is a DIFFERENT
  // DOCUMENT, and `resume` deliberately does not require a handler to advance
  // from connect to signing. A hook would therefore be unreachable on exactly
  // the hop it exists to guard, and would silently not run there — the worst of
  // the three outcomes. A string survives the redirect; a function does not.
  // A cluster reduced to the string walletSession will compare it as. Absent,
  // null and '' all collapse to the same value on both sides, so a host that
  // never declares a cluster still gets a consistent scope rather than a session
  // it can store and never recall.
  function scopeCluster(cluster) {
    return (cluster === null || cluster === undefined) ? '' : String(cluster);
  }

  function shortAddress(address) {
    var s = String(address);
    return s.length > 12 ? s.slice(0, 4) + '…' + s.slice(-4) : s;
  }

  // Whatever the transport learned, reduced to an address string.
  //
  // WHAT THIS DELIBERATELY DOES NOT DO: construct, parse, or call into a web3
  // object. `String(pk)` is the one thing a base58 string and a
  // `solanaWeb3.PublicKey` both answer correctly, and stringifying a value
  // someone handed us is not a dependency on the library that made it. Anything
  // more — `.toBase58()`, `new PublicKey(...)` — would put web3.js on this
  // gem's critical path, which is the boundary the wire-bytes contract exists
  // to hold.
  function connectedAddress(result, provider) {
    var pk = (result && (result.publicKey || result.public_key)) ||
             (provider && provider.publicKey) || null;
    var s = pk ? String(pk) : '';
    // '[object Object]' is what a provider handing back something with no
    // meaningful toString produces. Reporting THAT as the connected account
    // puts a wrong-wallet sentence in front of someone whose wallet is fine, so
    // it reads as unknown instead and takes the unreadable branch below.
    return (s && s.indexOf('[object') !== 0) ? s : null;
  }

  // Undeclared expectation → nothing happens, on every transport. This is the
  // branch every existing consumer is on, and it must stay free.
  function assertExpectedAccount(expected, connected) {
    if (!expected) return;
    if (!connected) {
      throw new Error(
        'This wallet did not say which account it connected as, so the ' +
        'expected account could not be checked — reconnect and try again'
      );
    }
    if (String(connected) === String(expected)) return;
    // The message is what a user READS: studio-engine's wallet callback paints
    // err.message directly. The full addresses ride on the error for a host
    // that would rather compose its own sentence.
    var e = new Error(
      'Wrong wallet — this account is linked to ' + shortAddress(expected) +
      ', but the wallet connected as ' + shortAddress(connected) +
      '. Switch accounts in your wallet and try again.'
    );
    e.wrongAccount = true;
    e.expected = String(expected);
    e.connected = String(connected);
    throw e;
  }

  // --- inline transport ----------------------------------------------------
  //
  // The provider is injected, promises resolve, nothing is written down. It
  // stays deliberately close to what the existing desktop call sites do, so
  // adopting walletOps is not also a rewrite of the flow that already worked —
  // but it is no longer a DIFFERENT contract from the redirect path, which is
  // what kept every consumer maintaining two of them.
  //
  // CONNECT COMES BEFORE PREPARE, and the order is the point. `prepare` is a
  // server round trip that MINTS something — turf-monster's is a prepared
  // transaction row with a fresh blockhash — so running it before the wallet
  // has said who it is spends a real record to discover the wrong account is
  // connected. Every hand-rolled desktop call site this replaces already
  // connected first for exactly that reason, and a walletOps that prepared
  // first would have made migrating to it a regression.
  //
  // THE REDIRECT TRANSPORT CANNOT COPY THIS, and no amount of shuffling makes
  // it: the connect hop DESTROYS the page, so anything prepare returns must
  // already be in the journal before the navigation. See runRedirect.
  //
  // WHAT DOES NOT FOLLOW FROM THAT ORDER: `prepare` is still called with `ctx`
  // and nothing else. An intent that read the connected account here would work
  // on a desktop and silently misbehave on a cold mobile session, where the
  // account is not known until a page that no longer exists.
  function runInline(name, ctx, opts) {
    var handler = requireHandler(name);
    var provider = opts.provider;

    return Promise.resolve().then(function () {
      requireInlineCodec(provider);
      return provider.connect();
    }).then(function (connection) {
      assertExpectedAccount(opts.expectedAccount, connectedAddress(connection, provider));
      return handler.prepare(ctx);
    }).then(function (prepared) {
      requireWireTransaction(name, prepared);
      // `prepared` is NOT mutated. `complete` is handed the object `prepare`
      // returned, byte for byte, so `state.transaction` is the same base58
      // string on both transports — a deserialized copy left in there would
      // reintroduce the split one layer down.
      return Promise.resolve(
        provider.signTransaction(provider.deserializeTransaction(prepared.transaction))
      ).then(function (signed) {
        return handler.complete(ctx, {
          // BACK TO WIRE BYTES BEFORE `complete` SEES THEM. Without this the
          // redirect path hands over a base58 string and the inline path hands
          // over a signed Transaction object, the call site branches on which,
          // and the one-call-site promise is lost on the return leg instead of
          // the outbound one.
          signedTransaction: provider.serializeTransaction(signed),
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
      // The SAME contract the inline path enforces, checked before anything is
      // written down. A transaction that is not wire bytes cannot be journalled
      // — it would serialise to `{}` and reach the wallet as an invalid payload
      // one page death from the handler that caused it.
      requireWireTransaction(name, prepared);

      var intent = { op: name, ctx: ctx, state: prepared };

      // THE DECLARATION TRAVELS IN THE JOURNAL, NOT LOOKED UP FROM THE HANDLER
      // AT THE FAR END, and that is the whole reason this line exists here
      // rather than inside signingHop. The signing hop is taken from TWO
      // places: this one, where the handler is certainly registered, and the
      // connect callback, which is a DIFFERENT PAGE that may not have loaded
      // the script that defined this intent. A handler lookup there would come
      // back empty and silently fall through to the send-side default — the
      // exact branch a co-signed transaction must never take. A boolean on the
      // intent is JSON-serialisable, which is the one thing this file requires
      // of anything that has to survive a redirect.
      //
      // Set ONLY when true, so the journal an undeclared intent writes is
      // byte-identical to the one it wrote before this option existed. That is
      // also why JOURNAL_VERSION does not move: no reader's expectations
      // change, and bumping it would strand every trip already in flight.
      if (handler.signOnly) intent.signOnly = true;

      // THE EXPECTED ACCOUNT RIDES THE SAME WAY, AND FOR THE SAME REASON. It is
      // checked on the connect callback — a different document, which may never
      // have run define() — so it cannot be looked up from the handler there.
      //
      // NOTE WHAT THIS COSTS ON THIS TRANSPORT, because it is a real cost and
      // the inline path does not pay it: `prepare` has ALREADY run by the time
      // we get here, so a wrong wallet on a cold mobile session still spends
      // whatever prepare minted. It cannot be otherwise — the connect hop
      // destroys this page, and the journal is the only thing that crosses it,
      // so prepare's state must exist before we navigate. What the declaration
      // buys on this transport is a sentence instead of a program error, and no
      // signing prompt for a transaction that could never have been accepted.
      //
      // Set ONLY when present, so an undeclared intent's journal stays
      // byte-identical to the one it wrote before this option existed —
      // the same rule signOnly follows, and the same reason JOURNAL_VERSION
      // does not move.
      if (opts.expectedAccount) intent.expectedAccount = String(opts.expectedAccount);

      // Already connected? Go straight to signing. Otherwise connect first and
      // carry the intent through — sessions do not expire on any of the three
      // wallets, so this branch is taken once per user, not once per action.
      //
      // THAT SENTENCE WAS ONLY TRUE FOR A CALLER THAT KEPT THE SESSION ITSELF.
      // Nothing did, so every trip paid the connect hop and the "once per user"
      // claim described a code path nobody was on. `opts.owner` is what makes it
      // literal: walletSession recalls the stored session for this exact
      // (owner, wallet, cluster), and a returning user signs in ONE hop.
      var existing = opts.session || null;
      // WHETHER *WE* RECALLED IT, which is a different question from "is there a
      // session". A caller that hands in `opts.session` owns that session: this
      // file did not store it, has no record of it, and must not offer to
      // recover or forget it. Recovery is a service for the sessions walletOps
      // itself recalled, and this flag is what keeps the two apart.
      var recalled = false;
      if (!existing && opts.owner) {
        var stored = studio().walletSession.recall({
          owner: opts.owner,
          wallet: provider.key,
          cluster: opts.cluster,
          // Checked HERE, where it is free. A warm trip takes no connect hop, so
          // this is the only place a declared expectation can be honoured before
          // the user is committed. A mismatch is a miss, not an error — the trip
          // falls through to the connect hop below and is checked there.
          expectedAccount: opts.expectedAccount
        });
        if (stored) { existing = stored.credentials; recalled = true; }
      }

      // A TRIP THAT SKIPS THE CONNECT HOP HAS NO CONNECT HOP TO FALL BACK ON,
      // so it writes down how to build one. The wallet can refuse a stored
      // session mid-trip — vendor docs name an explicit disconnect, a keypair
      // change, a network switch and an app_url blocklisting — and by then the
      // user has already committed. The refusal arrives on the SIGNING callback,
      // a different document that knows none of these values, so they travel in
      // the journal for the same reason signOnly and expectedAccount do.
      //
      // `scope` is WHO this trip belongs to; `recovery` is HOW to rebuild the
      // connect. They are deliberately separate records, on two different
      // conditions:
      //
      //   scope    — whenever an owner is declared, warm or COLD. The cold trip
      //              is where a session is first learned, and the connect
      //              callback is a different document that may know no owner of
      //              its own. Stamping it from the journal is also the SAFER
      //              read: the session belongs to whoever started the trip, not
      //              to whoever happens to be signed in at the browser when the
      //              wallet answers.
      //   recovery — only on a trip that skipped the connect hop USING A SESSION
      //              WE RECALLED. Gated on `recalled`, not on `existing`: a
      //              caller-supplied `opts.session` also skips the hop, but this
      //              file has no record of it, so forgetting it would evict a
      //              DIFFERENT scope's session and the recovery would have no
      //              cluster to rebuild the connect with. The retry keeps scope
      //              and drops recovery, which bounds recovery to once. See
      //              recoverThroughConnect.
      //
      // Both set ONLY when the new options are used, so a caller that declares
      // no owner writes a journal byte-identical to the one it wrote before this
      // feature existed — INCLUDING one that supplies its own `opts.session`,
      // which is the case the `existing` gate used to get wrong. Same rule
      // signOnly follows, and the same reason JOURNAL_VERSION does not move.
      if (opts.owner) {
        intent.scope = { owner: String(opts.owner), cluster: scopeCluster(opts.cluster) };
      }
      if (recalled) {
        intent.recovery = { appUrl: opts.appUrl || null, redirectLink: opts.redirectLink || null };
      }

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

  // Which signing method this wallet gets is TWO questions asked in order, and
  // the order is the point.
  //
  // FIRST, what does the TRANSACTION allow? A co-signed transaction has an
  // empty signer slot the server fills, so the wallet must sign and hand the
  // bytes back — broadcasting it is not a worse option, it is a broken one.
  // An intent that knows this declares `signOnly` and that answer is final.
  //
  // SECOND, and only for everything else, what can the WALLET do? Phantom's
  // send-side deeplink is deprecated, so it signs and the app broadcasts;
  // Solflare and Backpack broadcast for you. Asking the provider keeps that
  // fact in the profile table where it is asserted, rather than branching on a
  // wallet name here.
  //
  // Asking them the other way round is the bug this replaced: capability alone
  // sent every co-signed transaction to the wallet's broadcaster on any wallet
  // that had one.
  //
  // A wallet with no signTransaction at all would be refused BY NAME by the
  // provider's own capability gate rather than quietly broadcast here. No
  // profile is in that state today (all three sign), and this is the branch
  // that would have to be revisited if one ever were.
  function signingHop(provider, journal, opts) {
    var intent = journal.intent;
    var payload = {
      journal: journal,
      transaction: intent.state.transaction,
      redirectLink: opts.redirectLink,
      intent: intent
    };
    var signOnly = !!(intent && intent.signOnly);
    return (!signOnly && provider.can('signAndSendTransaction'))
      ? provider.beginSignAndSendTransaction(payload)
      : provider.beginSignTransaction(payload);
  }

  // --- the persisted session -----------------------------------------------
  //
  // WRITTEN ON THE CONNECT CALLBACK, which is the one moment this transport
  // holds all four credential fields AND the address they belong to. Everything
  // after this is a lookup.
  //
  // The scope is read off the JOURNAL first and `opts` only as a fallback, and
  // the order is the safety property, not a convenience. The journal says who
  // STARTED the trip; `opts` says who is signed in at the browser when the
  // wallet answers. Those are the same person in every ordinary case, and when
  // they differ — a shared phone, a logout mid-trip — stamping the CURRENT user
  // onto a wallet session someone else established is the one outcome that lets
  // a stranger sign. Stamping the originator cannot: the next recall names a
  // different owner and misses.
  //
  // A trip that declared no owner anywhere is simply not remembered. That is the
  // behaviour every caller had before this existed, and it costs one app switch,
  // not a signature.
  function rememberSession(journal, connected, opts) {
    var intent = connected.journal && connected.journal.intent;
    var scope = (intent && intent.scope) || null;
    var owner = (scope && scope.owner) || opts.owner || null;
    if (!owner) return false;

    return studio().walletSession.remember({
      owner: owner,
      wallet: journal.wallet,
      cluster: scope ? scope.cluster : scopeCluster(opts.cluster),
      publicKey: connected.publicKey,
      credentials: {
        dappSecretKey: connected.journal.dappSecretKey,
        dappPublicKey: connected.journal.dappPublicKey,
        walletPublicKey: connected.journal.walletPublicKey,
        session: connected.session
      }
    });
  }

  // THE REFUSAL PATH, AND THE REASON THIS FEATURE IS NOT JUST A CACHE.
  //
  // A stored session can be refused by the wallet mid-trip — vendor docs name an
  // explicit disconnect, a wallet keypair change, the user switching networks,
  // and an app_url blocklisting — and it is refused at the WORST possible
  // moment: the user has already left for their wallet app and come back, so
  // they are committed. Failing there loses whatever they were doing, which is
  // exactly the class of loss this epic exists to remove (a real user's entry
  // was lost on QA in this second hop).
  //
  // So the trip does not fail; it takes the hop it skipped. Forget the session,
  // navigate to connect carrying THE SAME INTENT, and the ordinary connect
  // callback picks it up and advances to signing on its own. The user pays one
  // extra app switch — the two-hop cost they would have paid anyway — instead of
  // starting over.
  //
  // `prepare()` IS NOT RE-RUN, and that is the point of reusing the journalled
  // intent rather than rebuilding one. prepare MINTS things — turf-monster's
  // mints a prepared-transaction row with a fresh blockhash — so re-running it
  // would strand the first one and charge the flow twice for one user action.
  // `intent.state` came back from the original prepare and is signed unchanged.
  //
  // ONCE, STRUCTURALLY. The retry intent carries `scope` but NOT `recovery`, so
  // the hop it produces cannot recover again; a second refusal surfaces the
  // wallet's own words. That is a shape, not a counter — there is no field to
  // forget to decrement.
  //
  // AND IT RESTORES A GUARD THE WARM PATH GIVES UP. A session-skipping trip
  // never learns which account connected, so a declared expectedAccount goes
  // unchecked on it. The recovered trip goes through connect, where it IS
  // checked — so the recovery from a keypair change ends in a sentence the user
  // can act on rather than a chain error.
  function recoverThroughConnect(provider, journal, opts, navigate) {
    var intent = journal.intent;
    var recovery = intent && intent.recovery;
    // No recovery block means this trip already had a connect hop, or ran on a
    // session this file never stored. There is nothing better to do than report
    // what the wallet said.
    if (!recovery) return null;

    // A recovery block is only ever written beside a scope (both come from the
    // same recall), so this is unreachable from a journal THIS release wrote.
    // It is checked anyway because the alternative is silent and expensive: the
    // cluster below would be null, `query()` drops a null, and the wallet would
    // default the recovered connect to MAINNET-BETA — real funds on a trip that
    // began on devnet. A journal from an older release is exactly the way that
    // becomes reachable.
    if (!intent.scope) return null;

    // The redirect link is what the wallet returns to. Since #44, url.connect
    // REFUSES to build without one, and that throw would escape this function
    // and reach the user INSTEAD of the wallet's own error — a worse report
    // about a different subject. Answer null and let the wallet speak.
    var redirectLink = opts.redirectLink || recovery.redirectLink;
    if (!redirectLink) return null;

    // Only now, once the retry is certain to be buildable. Forgetting before
    // this point would drop the session on a trip that then reports the wallet's
    // error anyway, costing the user a stored session for nothing.
    studio().walletSession.forget();

    var again = { op: intent.op, ctx: intent.ctx, state: intent.state };
    if (intent.signOnly) again.signOnly = true;
    if (intent.expectedAccount) again.expectedAccount = intent.expectedAccount;
    again.scope = intent.scope;

    var begun = provider.beginConnect({
      appUrl: recovery.appUrl,
      redirectLink: redirectLink,
      // THE CLUSTER THE TRIP BEGAN ON, never null. See the scope guard above.
      cluster: intent.scope.cluster,
      intent: again
    });

    // A store that cannot record the retry cannot complete it either. Returning
    // null hands the caller back to the wallet's own error, which is a truer
    // report than "could not record" for a user whose browser just refused a
    // write.
    if (!studio().walletJournal.save(begun.journal)) return null;
    navigate(begun.url);
    return { pending: true, suspended: true, recovered: true, url: begun.url };
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
          // A PLAIN SIGN-IN IS THE MOST VALUABLE SESSION THERE IS, because it is
          // the one every user establishes before they ever ask to sign
          // anything. Remembering it here is what makes a returning user's FIRST
          // action one hop rather than their second. The host owns this connect
          // (walletOps did not start it), so the owner can only come from opts.
          rememberSession(journal, connected, opts);
          return Promise.resolve({ pending: true, done: true, connect: connected });
        }

        // THE ONE MOMENT THIS TRANSPORT LEARNS WHO CONNECTED, and the last one
        // before a signing prompt. Read off the JOURNAL, not a handler: this
        // document may never have loaded the script that defined the intent,
        // and the whole point of resume advancing without one is that it does
        // not have to. The journal has already been taken, so a refusal here
        // ends the trip cleanly rather than leaving half a request behind.
        //
        // A WARM SESSION NEVER REACHES THIS. `run` with an `opts.session`
        // takes no connect hop at all, so there is no account for walletOps to
        // check — a caller holding a session already learned the address when
        // it established one, and that is where it belongs.
        assertExpectedAccount(intent.expectedAccount, connected.publicKey);

        // AFTER the account guard, never before. A wrong wallet must not evict
        // the session belonging to the right one — and a session stored for an
        // account the caller has already refused is a record that can only ever
        // be recalled into the same refusal.
        rememberSession(journal, connected, opts);

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
        var out;
        try {
          out = wallet
            ? provider.completeSignAndSendTransaction(params, journal)
            : provider.completeSignTransaction(params, journal);
        } catch (walletError) {
          // WHICH FAILURES RECOVER, stated as one rule: an error the WALLET
          // reported, that is not the user saying no.
          //
          // `code` is set only by throwIfWalletError, so its presence IS "the
          // wallet answered with an error redirect" — the channel every
          // documented refusal cause arrives on. `rejected` (4001) is carved out
          // because a user who declined has a perfectly good session and being
          // sent back to their wallet for another look is hostile.
          //
          // Deliberately WIDER than the four documented causes. Their codes are
          // not pinned here, and guessing a narrow list wrong costs the user
          // their entry — the exact failure this feature removes — while
          // guessing wide costs one app switch and then surfaces the same error
          // honestly, because the retry cannot recover again. When the two
          // mistakes are that asymmetric, take the cheap one.
          //
          // DECRYPTION FAILURES ARE NOT IN THIS RULE, and that is on purpose:
          // they carry no `code`, they are not a refusal channel any vendor
          // documents, and a corrupt payload is a different finding that should
          // read as itself rather than as a session problem.
          if (!walletError.code || walletError.rejected) throw walletError;
          var recovered = recoverThroughConnect(provider, journal, opts, navigate);
          if (recovered) return Promise.resolve(recovered);
          throw walletError;
        }
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
      // REFUSED RATHER THAN COERCED, because every wrong answer here fails in
      // the dangerous direction. A typo'd `signOnly: 'true'` read as truthy
      // would sign-only a flow that wanted the wallet to broadcast; read
      // strictly, it silently sends a co-signed transaction to a broadcaster.
      // Neither is discoverable at the call site, and both surface as a chain
      // error one page death later. So the option is a boolean or it is a bug.
      if (handler.signOnly !== undefined && typeof handler.signOnly !== 'boolean') {
        throw new Error(
          'walletOps.define("' + name + '") signOnly must be true or false, got ' +
          typeof handler.signOnly
        );
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
      // REFUSED RATHER THAN STRINGIFIED. A `solanaWeb3.PublicKey` passed here
      // would String() correctly on the inline path and be written to the
      // journal as `{}` on the redirect one — matching on a desktop and
      // refusing every mobile trip with a wrong-wallet sentence naming an
      // account nobody has. The two transports disagreeing about a value is
      // precisely the failure this whole change exists to remove.
      if (opts.expectedAccount !== undefined && opts.expectedAccount !== null &&
          typeof opts.expectedAccount !== 'string') {
        return Promise.reject(new Error(
          'walletOps.run expectedAccount must be a base58 address string, got ' +
          typeof opts.expectedAccount + ' — call .toString() on a PublicKey first'
        ));
      }
      // REFUSED RATHER THAN STRINGIFIED, and for a sharper reason than
      // expectedAccount's. An object here would String() to '[object Object]' —
      // ONE owner token that every user of this browser matches — and the
      // symptom would be a stranger offered a one-hop signature with a wallet
      // session they never established. walletSession.remember() refuses the
      // same value on its own, so nothing can actually be stored under it; this
      // check exists so the bug is named at the call site that wrote it rather
      // than showing up as a feature that quietly never works.
      if (opts.owner !== undefined && opts.owner !== null &&
          typeof opts.owner !== 'string' && typeof opts.owner !== 'number') {
        return Promise.reject(new Error(
          'walletOps.run owner must be a string or number identifying the ' +
          'signed-in user, got ' + typeof opts.owner + ' — an object would ' +
          'stringify to one token every user shares'
        ));
      }
      return opts.provider.transport === 'redirect'
        ? runRedirect(name, ctx, opts)
        : runInline(name, ctx, opts);
    },

    resume: resume
  };
})(typeof window !== 'undefined' ? window : globalThis);
