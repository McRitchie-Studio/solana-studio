// SolanaStudio.walletJournal — the only thing that survives the page's death.
//
// A redirect destroys the document. Whatever the app needs on the other side has
// to be written down first, and this is where. Everything else about the
// redirect transport is pure functions over data; this file is the one place
// that touches storage, which is why it is small and separately testable.
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

  function save(journal) {
    var s = store();
    if (!s || !journal) return false;
    try {
      s.setItem(KEY, JSON.stringify(journal));
      return true;
    } catch (e) {
      // Quota, private mode, or a disabled store. The caller is about to
      // navigate to a wallet; telling it the write failed lets it refuse the
      // trip rather than take one it can never complete.
      return false;
    }
  }

  // Read WITHOUT clearing. For a callback page that wants to inspect before
  // committing to advancing — the resume path uses take().
  function peek() {
    var s = store();
    if (!s) return null;
    var raw;
    try {
      raw = s.getItem(KEY);
    } catch (e) {
      return null;
    }
    if (!raw) return null;

    var journal;
    try {
      journal = JSON.parse(raw);
    } catch (e) {
      // Corrupt entry: drop it rather than leave it to fail every future read.
      clear();
      return null;
    }

    if (!journal || typeof journal !== 'object') { clear(); return null; }

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
    var s = store();
    if (!s) return;
    try { s.removeItem(KEY); } catch (e) { /* nothing to do and nothing to say */ }
  }

  // Purge every key this subsystem owns. A host calls this on user switch: a
  // journal belongs to the person who started it, and one that outlived a logout
  // would offer to resume a stranger's signature.
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
})(typeof window !== 'undefined' ? window : globalThis);
