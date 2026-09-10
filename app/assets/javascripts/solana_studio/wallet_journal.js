// The redirect transport's STORAGE — the only thing that survives the page's
// death. Two records, two opposite lifetimes, one store.
//
//   SolanaStudio.walletJournal — ONE TRIP. Single-use, expiring.
//   SolanaStudio.walletSession — ONE WALLET, ONE USER. Long-lived, reusable.
//
// A redirect destroys the document. Whatever the app needs on the other side has
// to be written down first, and this is where. Everything else about the
// redirect transport is pure functions over data; this file is the one place
// that touches storage, which is why it is small and separately testable.
//
// WHY THE SESSION LIVES HERE AND NOT IN A FILE OF ITS OWN, since the two records
// could hardly be more different. Everything about reaching localStorage safely
// — the guarded accessor, the three browser states it really presents, the
// quota branch, the corrupt-entry drop — is one algorithm, and a second file
// would be a second copy of it. This codebase has already been bitten by exactly
// that (see the B58_ALPHABET note in wallet_transport.js, and the "one factory,
// not three adapters" note in redirect_provider.js). What must be separate is
// the RECORD, not the file, and the records below share no key, no lifetime and
// no reader.
//
// It also keeps `purge()` whole. Purge sweeps by PREFIX, so a session stored
// under that prefix is cleared on logout by the call a host ALREADY makes. Split
// the file and a host that upgrades without adding a second purge call ships a
// session that outlives a logout — which is a stranger signing.
//
// THE NAME ON THE FILE IS NOW NARROWER THAN ITS CONTENTS, and that is a
// deliberate cost, not an oversight. The path is shipped: consumers load
// `solana_studio/wallet_journal.js` from a script tag, lib/solana_studio/engine.rb
// precompiles it by name, and test/gemspec_test.rb pins it. Renaming a shipped
// asset path to improve a noun breaks every consumer at once.
//
// WHY NOT sessionStorage. The wallet round trip leaves the browser entirely and
// may return in a NEW TAB — iOS in particular does not guarantee the originating
// tab is what receives a universal link. sessionStorage is per-tab and would be
// empty exactly when it mattered. localStorage is the only store that survives
// the trip, which is also why the entries below expire and are single-use.
//
// SINGLE-USE, AND EXPIRING, BOTH ON PURPOSE. A journal that lingers is a journal
// that gets replayed: a user who abandons a signature, wanders off and comes back
// an hour later should get a clean "start again", not a resumed transaction they
// have forgotten authorising. `take()` reads and clears in one motion so a
// double-fired callback cannot advance the same step twice.
//
// WHAT MUST NEVER BE WRITTEN HERE, stated positively because the temptation is
// real: no private keys belonging to the user, no unsigned transaction bytes, no
// personal data. The dapp's ephemeral encryption secret IS here and is safe —
// see the note in redirect_provider.js. Transactions stay server-side behind a
// prepared-transaction slug, which is precisely why that slug exists.
(function (W) {
  'use strict';

  W.SolanaStudio = W.SolanaStudio || {};

  var PREFIX = 'wallet_dl';
  var KEY = PREFIX + '_journal';
  var SESSION_KEY = PREFIX + '_session';

  // Ten minutes. Long enough for a human to read a wallet approval screen,
  // think, and approve; short enough that an abandoned trip is gone before it
  // can be resumed by accident. Phantom's own nonce guidance is looser than
  // this, so the tighter bound is ours and deliberate.
  var MAX_AGE_MS = 10 * 60 * 1000;

  // EVERY access is guarded. localStorage throws outright in a Safari private
  // window and in some embedded webviews — the exact browsers a mobile wallet
  // flow runs in. A storage failure must degrade to "no pending request", never
  // to an exception thrown out of a callback page that then renders nothing.
  function store() {
    try {
      return W.localStorage || null;
    } catch (e) {
      return null;
    }
  }

  // --- the shared record primitives ----------------------------------------
  //
  // Both records go through these. Written once because the interesting part is
  // not the JSON, it is the failure handling around it, and two copies of that
  // is how one of them quietly stops guarding.

  function writeRecord(key, record) {
    var s = store();
    if (!s || !record) return false;
    try {
      s.setItem(key, JSON.stringify(record));
      return true;
    } catch (e) {
      // Quota, private mode, or a disabled store. The caller is about to
      // navigate to a wallet; telling it the write failed lets it refuse the
      // trip rather than take one it can never complete.
      return false;
    }
  }

  function readRecord(key) {
    var s = store();
    if (!s) return null;
    var raw;
    try {
      raw = s.getItem(key);
    } catch (e) {
      return null;
    }
    if (!raw) return null;

    var record;
    try {
      record = JSON.parse(raw);
    } catch (e) {
      // Corrupt entry: drop it rather than leave it to fail every future read.
      removeRecord(key);
      return null;
    }
    if (!record || typeof record !== 'object') { removeRecord(key); return null; }
    return record;
  }

  function removeRecord(key) {
    var s = store();
    if (!s) return;
    try { s.removeItem(key); } catch (e) { /* nothing to do and nothing to say */ }
  }

  function save(journal) {
    return writeRecord(KEY, journal);
  }

  // Read WITHOUT clearing. For a callback page that wants to inspect before
  // committing to advancing — the resume path uses take().
  function peek() {
    var journal = readRecord(KEY);
    if (!journal) return null;

    if (typeof journal.startedAt === 'number' && (Date.now() - journal.startedAt) > MAX_AGE_MS) {
      // EXPIRED IS NOT AN ERROR, it is an answer. Clearing here means the next
      // read reports "nothing pending" instead of re-deciding expiry forever.
      clear();
      return null;
    }

    return journal;
  }

  // Read and clear in one motion. The resume path uses this so a callback that
  // fires twice — a reload, a back button — cannot advance the same step twice.
  function take() {
    var journal = peek();
    if (journal) clear();
    return journal;
  }

  function clear() {
    removeRecord(KEY);
  }

  // Purge every key this subsystem owns — BOTH records. A host calls this on
  // user switch: a journal belongs to the person who started it, and one that
  // outlived a logout would offer to resume a stranger's signature. The wallet
  // session below is the same hazard with a longer fuse, and it is swept by the
  // same call because it is stored under the same PREFIX.
  function purge() {
    var s = store();
    if (!s) return;
    try {
      var doomed = [];
      for (var i = 0; i < s.length; i++) {
        var k = s.key(i);
        if (k && k.indexOf(PREFIX) === 0) doomed.push(k);
      }
      for (var j = 0; j < doomed.length; j++) s.removeItem(doomed[j]);
    } catch (e) { /* a store we cannot enumerate is a store with nothing to purge */ }
  }

  W.SolanaStudio.walletJournal = {
    KEY: KEY,
    PREFIX: PREFIX,
    MAX_AGE_MS: MAX_AGE_MS,
    save: save,
    peek: peek,
    take: take,
    clear: clear,
    purge: purge,
    // Whether a journal could be persisted at all. A caller that cannot write
    // must not start a redirect it will be unable to finish — it should fall
    // back to the browse handoff, which needs no journal.
    writable: function () {
      var s = store();
      if (!s) return false;
      try {
        var probe = PREFIX + '_probe';
        s.setItem(probe, '1');
        s.removeItem(probe);
        return true;
      } catch (e) {
        return false;
      }
    }
  };

  // === SolanaStudio.walletSession ==========================================
  //
  // THE RECORD THAT MAKES A RETURNING USER ONE HOP. Every mobile signing trip
  // costs two app switches today — connect, then sign — and the second one is
  // paid over and over for a session that, per Phantom's, Solflare's and
  // Backpack's own docs (verified 2026-09-07, recorded in redirect_provider.js's
  // profile table), NEVER EXPIRES. Nothing wrote it down, so nothing could reuse
  // it. This is the writing down.
  //
  // THE OPPOSITE OF THE JOURNAL IN EVERY DIMENSION THAT MATTERS, which is why it
  // is a separate record rather than another field on one:
  //
  //            journal                       session
  //   reads    take() — clears               recall() — leaves it in place
  //   life     10 minutes                    until invalidated (see below)
  //   scope    one trip                      one wallet, for one user
  //
  // Share the record and every completed trip would take() the session away with
  // it, which is precisely the two-hop behaviour this exists to remove.
  //
  // WHAT INVALIDATES IT — the complete list, and there is no timer in it:
  //
  //   1. The WALLET refuses it. Vendor docs name the causes: an explicit
  //      disconnect, a wallet keypair change, the user switching networks, an
  //      app_url blocklisting. walletOps forgets the session and recovers the
  //      trip through a connect hop; see wallet_ops.js.
  //   2. The SCOPE no longer matches — a different user, wallet or cluster.
  //      That is a miss, not an error: the caller takes an ordinary connect hop.
  //   3. purge(), which a host calls on logout or user switch.
  //   4. forget(), for an explicit disconnect in the app's own UI.
  //
  // No max age, deliberately. Inventing one would contradict the vendor fact
  // this feature rests on and would re-introduce the second hop on a schedule.
  //
  // THE TOKEN IS OPAQUE AND STAYS OPAQUE. It decodes to a 64-byte signature plus
  // JSON carrying app_url, timestamp, chain and cluster — and none of that is
  // read here, on purpose. The WALLET is the only authority on whether a session
  // is still good; a local parse can only ever produce a second opinion that is
  // wrong in one of two directions. Nothing below decodes, validates, or
  // inspects `credentials.session`. It is stored as given and handed back as
  // given.
  //
  // WHAT IS STORED, AND THE ONE THING WORTH SAYING OUT LOUD. The credentials
  // block is exactly the four fields the signing hop needs, and one of them is
  // the dapp's ephemeral secret key. redirect_provider.js explains why that is
  // safe — a per-connect x25519 keypair that cannot sign, spend or authorise
  // anything, whose loss costs one reconnect — and that argument is unchanged
  // here. What DOES change is its lifetime: it now lives until an invalidation
  // above rather than ten minutes. The blast radius is still "can decrypt this
  // app's wallet replies on this device", and purge() on logout is what keeps it
  // from outliving the person it belongs to.
  //
  // NO user private key, NO unsigned transaction bytes, NO personal data — the
  // same rule the journal keeps, and the owner token below is the host's own
  // opaque handle, not an email or a name.
  var SESSION_VERSION = 1;

  // A scope value, reduced to the string it will be compared as. Numbers are
  // accepted because a host's user id usually IS one; anything else is refused
  // by owner() below rather than stringified.
  function scopeValue(v) {
    return (v === null || v === undefined) ? '' : String(v);
  }

  // The owner is the whole reason a session cannot be a stranger's.
  //
  // REFUSED RATHER THAN STRINGIFIED, and this is the guard that matters most in
  // the file. An object handed in here would String() to '[object Object]' —
  // one token that EVERY user matches — and the failure would be a stranger
  // signing with a wallet session they never established, on a shared device,
  // discovered by nobody. A string or a number is a real handle; anything else
  // is a bug, and an unremembered session costs one extra app switch.
  function ownerToken(owner) {
    var t = typeof owner;
    if (t !== 'string' && t !== 'number') return null;
    var s = String(owner);
    return s === '' ? null : s;
  }

  // Persist the session for (owner, wallet, cluster). Returns whether it stuck —
  // a caller that cannot store one simply keeps paying the connect hop, which is
  // the behaviour it had before this record existed.
  //
  // ANONYMOUS IS REFUSED. A session with nobody to scope it to cannot be kept
  // away from the next person at this browser, and there is no logout event on
  // an anonymous page for purge() to ride. Not remembering costs one hop; the
  // alternative costs a signature.
  function remember(record) {
    if (!record) return false;
    var owner = ownerToken(record.owner);
    if (!owner) return false;

    var wallet = scopeValue(record.wallet);
    if (!wallet) return false;

    var c = record.credentials;
    // ALL FOUR OR NONE. The signing hop re-derives the shared secret from
    // walletPublicKey + dappSecretKey and puts `session` in the payload; a
    // record missing any of them would be recalled, used, and fail inside the
    // codec — a decryption error standing in for a storage bug, one page death
    // from here.
    if (!c || !c.session || !c.walletPublicKey || !c.dappSecretKey || !c.dappPublicKey) return false;

    return writeRecord(SESSION_KEY, {
      v: SESSION_VERSION,
      owner: owner,
      wallet: wallet,
      cluster: scopeValue(record.cluster),
      // The address this session signs as. Stored so a declared expectedAccount
      // can be checked BEFORE the trip rather than discovered by a wallet
      // refusal two app switches later.
      publicKey: record.publicKey ? String(record.publicKey) : null,
      credentials: {
        dappSecretKey: c.dappSecretKey,
        dappPublicKey: c.dappPublicKey,
        walletPublicKey: c.walletPublicKey,
        session: c.session
      },
      rememberedAt: Date.now()
    });
  }

  // The session for this exact scope, or null. `scope`:
  //   { owner, wallet, cluster, expectedAccount }  — expectedAccount optional.
  //
  // EXACT MATCH ON ALL THREE SCOPE FIELDS, and a miss is an ordinary answer that
  // costs a connect hop. There is ONE stored session rather than a table keyed
  // by scope, which is the honest model: a user who switches wallet or network
  // has changed their mind, and evicting the old one keeps "a stranger cannot
  // read this" a property of one stamped record instead of an invariant over a
  // growing set.
  function recall(scope) {
    scope = scope || {};
    var owner = ownerToken(scope.owner);
    if (!owner) return null;

    var record = readRecord(SESSION_KEY);
    if (!record) return null;

    // A VERSION WE DO NOT UNDERSTAND READS AS NO SESSION — note the contrast
    // with the journal, which THROWS on the same event. The journal is a trip in
    // flight, where carrying on would decrypt garbage and the only safe answer
    // is to stop loudly. Nothing is in flight here, and "connect again" is a
    // complete and correct answer, so a stale shape costs one hop and no words.
    if (record.v !== SESSION_VERSION) { forget(); return null; }

    if (record.owner !== owner) return null;
    if (record.wallet !== scopeValue(scope.wallet)) return null;
    if (record.cluster !== scopeValue(scope.cluster)) return null;

    // The account guard, applied where it is FREE. walletOps checks a declared
    // expectedAccount on the connect callback; a warm session takes no connect
    // hop, so without this the check would silently not happen on exactly the
    // trips this feature adds. A wallet keypair change would eventually be
    // refused by the wallet anyway — this turns two app switches and a refusal
    // into an immediate, correct connect hop.
    if (scope.expectedAccount && String(scope.expectedAccount) !== String(record.publicKey)) return null;

    if (!record.credentials || !record.credentials.session) { forget(); return null; }
    return record;
  }

  function forget() {
    removeRecord(SESSION_KEY);
  }

  W.SolanaStudio.walletSession = {
    KEY: SESSION_KEY,
    VERSION: SESSION_VERSION,
    remember: remember,
    recall: recall,
    forget: forget
  };
})(typeof window !== 'undefined' ? window : globalThis);
