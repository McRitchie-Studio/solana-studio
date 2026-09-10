// SolanaStudio.walletTransport — the REDIRECT transport's shared core.
//
// WHY THIS FILE EXISTS. `walletProvider` in the consuming apps models exactly one
// way of reaching a wallet: an object injected into the page. That is true of a
// desktop extension and of a wallet's own in-app browser, and it is false of
// every ordinary mobile browser. On iOS Safari and Android Chrome there is no
// injected provider, `detect()` returns null, and every call site that reaches
// for `provider.connect()` throws a null-dereference into a user-facing modal.
//
// The second transport is a REDIRECT: the page hands off to the wallet app by
// URL and the answer comes back on a callback URL, with the original page
// destroyed in between. A promise cannot survive that, which is the single fact
// this whole design is shaped around.
//
// WHAT THIS FILE IS AND IS NOT. It is the wallet-agnostic HALF: the codec, the
// per-wallet profile table, and the URL builders. It performs no navigation,
// touches no localStorage, and knows nothing about intents or resume — those
// belong to the journal (studio-engine) and the intent registry, which build ON
// this. Keeping them apart is what lets this half be exercised in node without a
// browser, which is how its per-wallet differences are actually pinned.
//
// THE PROTOCOLS ARE ~95% IDENTICAL, WHICH IS THE WHOLE OPPORTUNITY. Solflare and
// Backpack both forked Phantom's deeplink spec: same x25519 + nacl.box, same
// 24-byte nonce, base58 everywhere, byte-identical error tables, identical
// payload JSON keys, identical response keys. Solflare's own docs even link
// Phantom's blocklist repo. So the codec below is genuinely shared and only a
// small profile varies. Verified against all three vendors' live docs
// 2026-09-07; every divergence is recorded in PROFILES with its reason.
//
// ONE DEPENDENCY, AND IT IS GUARDED: window.nacl (tweetnacl). Base58 is INLINE
// and self-contained on purpose — a previous extraction left B58_ALPHABET behind
// at module scope where a classic script could not reach it, and every mobile
// sign-in threw "B58_ALPHABET is not defined" on the first keypair encode. That
// was invisible to eleven passing view tests and to a browser spec that checked
// `typeof` without ever CALLING the function. Nothing here reads a free
// variable it does not declare.
(function (W) {
  'use strict';

  W.SolanaStudio = W.SolanaStudio || {};

  var B58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  // CORRECTED DURING EXTRACTION, and deliberately NOT a faithful copy. Both
  // shipped encoders this was lifted from (turf-monster's deep link and
  // studio-engine's callback) seed `digits` with [0] and then convert EVERY
  // byte, including the leading zeros they also emit as '1' separately. For any
  // input that is entirely zero bytes that yields one character too many —
  // encode([0]) returns '11', which decodes back to [0, 0] — and encode([])
  // returns '1' rather than the empty string.
  //
  // NOT A LIVE BUG IN EITHER CONSUMER, and worth saying so plainly rather than
  // overstating the find: the only things they encode are 32-byte x25519 keys
  // and 24-byte nonces, and an all-zero one of either is not reachable. It is
  // still wrong, and a shared core that other code will build on should not
  // carry a round-trip that fails on its simplest input.
  //
  // The fix is to count the leading zero bytes, convert only what remains, and
  // let a zero value contribute no digits at all.
  function encodeBase58(bytes) {
    var zeros = 0;
    while (zeros < bytes.length && bytes[zeros] === 0) zeros++;

    var digits = [];
    for (var i = zeros; i < bytes.length; i++) {
      var carry = bytes[i];
      for (var j = 0; j < digits.length; j++) {
        carry += digits[j] << 8;
        digits[j] = carry % 58;
        carry = (carry / 58) | 0;
      }
      while (carry) { digits.push(carry % 58); carry = (carry / 58) | 0; }
    }

    var str = '';
    for (var k = 0; k < zeros; k++) str += '1';
    // The most significant digit of a non-zero number is never 0, so the '1'
    // characters above stay unambiguously the zero-byte prefix on decode.
    for (var m = digits.length - 1; m >= 0; m--) str += B58_ALPHABET[digits[m]];
    return str;
  }

  function decodeBase58(str) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var idx = B58_ALPHABET.indexOf(str[i]);
      if (idx < 0) throw new Error('Invalid base58 character');
      var carry = idx;
      for (var j = 0; j < bytes.length; j++) {
        carry += bytes[j] * 58;
        bytes[j] = carry & 0xff;
        carry >>= 8;
      }
      while (carry) { bytes.push(carry & 0xff); carry >>= 8; }
    }
    for (var k = 0; k < str.length && str[k] === '1'; k++) bytes.push(0);
    return new Uint8Array(bytes.reverse());
  }

  // --- Per-wallet profiles -------------------------------------------------
  //
  // Everything that is NOT shared. Each field below is a place one vendor
  // diverged, and each carries why — because the next reader's instinct will be
  // "these are all the same, collapse them", and four of them are traps.
  var PROFILES = {
    phantom: {
      name: 'Phantom',
      host: 'https://phantom.app',
      // Phantom's scheme has NO /ul/ segment. Solflare's does. This is the one
      // place a "just swap the host" adapter breaks.
      scheme: 'phantom://v1/',
      connectKeys: ['phantom_encryption_public_key'],
      // browse carries NO version segment on Phantom — documented that way, and
      // different from its own provider methods.
      browsePath: '/ul/browse/',
      clusters: ['mainnet-beta', 'testnet', 'devnet'],
      // DEPRECATED BY PHANTOM: "The signAndSendTransaction deeplink is
      // deprecated. Use signAllTransactions or signTransaction instead." So on
      // Phantom the APP still broadcasts — sendRawTransaction + a confirmation
      // poll stay. This is the opposite of the other two, and it applies to the
      // wallet most users hold, so it is not an edge case.
      send: 'app-broadcasts',
      methods: {
        connect: true, disconnect: true, signMessage: true,
        signTransaction: true, signAllTransactions: true,
        signAndSendTransaction: false, browse: true, signIn: false
      }
    },

    solflare: {
      name: 'Solflare',
      host: 'https://solflare.com',
      // KEEPS /ul/ — unlike Phantom. Evidence is Solflare's own sample app; the
      // scheme form is not documented in prose.
      scheme: 'solflare://ul/v1/',
      connectKeys: ['solflare_encryption_public_key'],
      browsePath: '/ul/v1/browse/',
      clusters: ['mainnet-beta', 'testnet', 'devnet'],
      send: 'wallet-broadcasts',
      methods: {
        connect: true, disconnect: true, signMessage: true,
        signTransaction: true, signAllTransactions: true,
        signAndSendTransaction: true, browse: true, signIn: false
      }
    },

    backpack: {
      name: 'Backpack',
      host: 'https://backpack.app',
      // NO custom scheme is documented anywhere in Backpack's corpus — universal
      // links only. Unlike Phantom there is no scheme fallback, so a caller that
      // needs one must handle null rather than assume a template.
      scheme: null,
      // Backpack's docs CONTRADICT THEMSELVES on this key: its encryption page
      // says wallet_encryption_public_key, its connect page says `wallet_xxx`,
      // which reads as an unresolved placeholder. Both are listed so the
      // resolver tries the documented name first and still works if the
      // placeholder turns out to be literal. Confirm on a device before trusting
      // either — this is the highest-risk unknown in the profile table.
      connectKeys: ['wallet_encryption_public_key', 'wallet_xxx'],
      browsePath: '/ul/v1/browse/',
      // DEVNET IS NOT DOCUMENTED for Backpack — its cluster parameter documents
      // only mainnet-beta (plus an Eclipse chain id). Consumers that test on
      // devnet cannot currently QA this wallet, which is a lane decision, not a
      // bug to paper over here. supportsCluster() reports it honestly.
      clusters: ['mainnet-beta'],
      send: 'wallet-broadcasts',
      methods: {
        connect: true, disconnect: true, signMessage: true,
        signTransaction: true, signAllTransactions: true,
        signAndSendTransaction: true, browse: true, signIn: false
      }
    }
  };

  // NO WALLET SHIPS A DOCUMENTED signIn DEEPLINK — every profile above says
  // false, and that is a measurement, not an oversight. Phantom's 404s in its
  // docs and exists only in its official demo app, where the payload is base58
  // PLAINTEXT rather than ciphertext and the response key is `address` or
  // `public_key` depending on version. Consumers currently depending on that
  // endpoint are depending on something unspecified. Mobile sign-in is
  // connect-then-signMessage — two hops — on all three wallets.

  function key(wallet) {
    return String(wallet == null ? '' : wallet).toLowerCase();
  }

  function profile(wallet) {
    return PROFILES[key(wallet)] || null;
  }

  // Can THIS wallet do THIS method over the redirect transport?
  //
  // The capability question is the one that prevents this whole bug class: a
  // button that renders without asking is how a null provider reached
  // `.connect()` in the first place. An unknown wallet answers false rather
  // than throwing — a caller asking about a wallet we have never heard of
  // wants "no", not an exception.
  function can(wallet, method) {
    var p = profile(wallet);
    return !!(p && p.methods[method] === true);
  }

  function supportsCluster(wallet, cluster) {
    var p = profile(wallet);
    return !!(p && p.clusters.indexOf(String(cluster)) !== -1);
  }

  // Which side broadcasts a signed transaction for this wallet.
  // 'app-broadcasts'    → sign only, then the app sends and confirms (Phantom)
  // 'wallet-broadcasts' → signAndSendTransaction returns a signature
  function sendStrategy(wallet) {
    var p = profile(wallet);
    return p ? p.send : null;
  }

  // Pull the wallet's encryption public key out of the connect redirect's query
  // params. This is the ONLY response key that differs between wallets, which is
  // exactly why it is resolved here instead of at call sites.
  //
  // `params` is anything with a .get (URLSearchParams, or a plain-object shim).
  function connectPublicKey(wallet, params) {
    var p = profile(wallet);
    if (!p || !params) return null;
    var get = typeof params.get === 'function'
      ? function (k) { return params.get(k); }
      : function (k) { return params[k]; };
    for (var i = 0; i < p.connectKeys.length; i++) {
      var v = get(p.connectKeys[i]);
      if (v) return v;
    }
    return null;
  }

  // --- Codec ---------------------------------------------------------------
  //
  // Shared by all three wallets without variation. Throws a NAMED error when
  // nacl is absent rather than a bare TypeError on `nacl.box` — the whole point
  // of a guarded dependency is that its absence reads as itself.
  function nacl() {
    if (!W.nacl) throw new Error('SolanaStudio.walletTransport requires tweetnacl (window.nacl)');
    return W.nacl;
  }

  var codec = {
    keypair: function () { return nacl().box.keyPair(); },

    sharedSecret: function (walletPublicKeyB58, dappSecretKey) {
      return nacl().box.before(decodeBase58(walletPublicKeyB58), dappSecretKey);
    },

    // Returns the two halves a request needs, both base58, ready to be query
    // params. The nonce is fresh per request — reusing one across requests under
    // the same shared secret is a real break, not a style preference.
    encrypt: function (payloadObject, sharedSecret) {
      var n = nacl();
      var nonce = n.randomBytes(24);
      var bytes = new TextEncoder().encode(JSON.stringify(payloadObject));
      return {
        nonce: encodeBase58(nonce),
        payload: encodeBase58(n.box.after(bytes, nonce, sharedSecret))
      };
    },

    decrypt: function (dataB58, nonceB58, sharedSecret) {
      var opened = nacl().box.open.after(
        decodeBase58(dataB58), decodeBase58(nonceB58), sharedSecret
      );
      if (!opened) throw new Error('Decryption failed — wrong shared secret or corrupt payload');
      return JSON.parse(new TextDecoder().decode(opened));
    }
  };

  // --- URL builders --------------------------------------------------------
  function base(wallet, useScheme) {
    var p = profile(wallet);
    if (!p) throw new Error('Unknown wallet: ' + wallet);
    // A caller may ASK for the scheme and not get it — Backpack documents none.
    // Falling back to the universal link is correct and silent here; refusing
    // would strand a caller that has a perfectly good link available.
    if (useScheme && p.scheme) return { profile: p, prefix: p.scheme };
    return { profile: p, prefix: p.host + '/ul/v1/' };
  }

  function query(pairs) {
    var parts = [];
    for (var k in pairs) {
      if (!Object.prototype.hasOwnProperty.call(pairs, k)) continue;
      if (pairs[k] === null || pairs[k] === undefined || pairs[k] === '') continue;
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(pairs[k]));
    }
    return parts.join('&');
  }

  // A REQUEST WITH NOWHERE TO RETURN IS NOT A REQUEST, and until this existed it
  // was possible to build one and impossible to notice. query() below SKIPS
  // null/undefined/empty values, so a missing redirect_link simply vanished from
  // the URL and the request looked perfectly well formed on the way out. Phantom
  // received it, had nothing to do with it, and opened to its HOME SCREEN — which
  // is indistinguishable, to a user, from the app being broken.
  //
  // Measured on a real iPhone against QA 2026-09-09: hop one (connect) completed
  // correctly and hop two was built with redirect_link undefined, because the
  // journal never carried it across the page death. The entry was lost after the
  // user had already approved it.
  //
  // Guarding at the BUILDER rather than at each call site is the point. There are
  // three places that construct these URLs today and more will follow; a rule
  // enforced where the string is assembled cannot be forgotten by the next one.
  function requireField(value, name, method) {
    if (value === null || value === undefined || value === '') {
      throw new Error(
        'Cannot build a ' + method + ' wallet request without ' + name +
        ' — the wallet would have nowhere to return to. This usually means the ' +
        'value was not carried across the redirect in the journal.'
      );
    }
    return value;
  }

  var url = {
    // connect carries NO nonce and NO payload — the shared secret does not exist
    // yet. Every other method requires both.
    connect: function (wallet, opts) {
      var b = base(wallet, opts && opts.useScheme);
      requireField(opts && opts.redirectLink, 'redirect_link', 'connect');
      requireField(opts && opts.dappPublicKey, 'dapp_encryption_public_key', 'connect');
      return b.prefix + 'connect?' + query({
        app_url: opts.appUrl,
        dapp_encryption_public_key: opts.dappPublicKey,
        redirect_link: opts.redirectLink,
        cluster: opts.cluster
      });
    },

    method: function (wallet, method, opts) {
      if (!can(wallet, method)) {
        throw new Error(wallet + ' does not support ' + method + ' over the redirect transport');
      }
      var b = base(wallet, opts && opts.useScheme);
      requireField(opts && opts.redirectLink, 'redirect_link', method);
      requireField(opts && opts.dappPublicKey, 'dapp_encryption_public_key', method);
      requireField(opts && opts.payload, 'payload', method);
      requireField(opts && opts.nonce, 'nonce', method);
      return b.prefix + method + '?' + query({
        dapp_encryption_public_key: opts.dappPublicKey,
        nonce: opts.nonce,
        redirect_link: opts.redirectLink,
        payload: opts.payload
      });
    },

    // The tier-3 handoff: open a page inside the wallet's own in-app browser,
    // where the INJECTED provider works and the existing inline transport needs
    // no changes at all. The target is a PATH segment, not a query param, and
    // the version segment differs per wallet — both encoded in browsePath.
    browse: function (wallet, targetUrl, refUrl) {
      var p = profile(wallet);
      if (!p) throw new Error('Unknown wallet: ' + wallet);
      if (!can(wallet, 'browse')) throw new Error(p.name + ' has no browse deeplink');
      return p.host + p.browsePath + encodeURIComponent(targetUrl) +
             '?' + query({ ref: refUrl });
    }
  };

  // Error redirects are IDENTICAL across all three wallets, codes included, so
  // this needs no per-wallet branch. Read it BEFORE attempting any decryption:
  // an error redirect carries no `data` and no `nonce`, so a decrypt-first
  // reader turns a clean user rejection into a decryption exception.
  var USER_REJECTED = '4001';

  function errorFrom(params) {
    if (!params) return null;
    var get = typeof params.get === 'function'
      ? function (k) { return params.get(k); }
      : function (k) { return params[k]; };
    var code = get('errorCode');
    if (!code) return null;
    return {
      code: String(code),
      message: get('errorMessage') || 'Wallet request failed',
      rejected: String(code) === USER_REJECTED
    };
  }

  W.SolanaStudio.walletTransport = {
    PROFILES: PROFILES,
    profile: profile,
    can: can,
    supportsCluster: supportsCluster,
    sendStrategy: sendStrategy,
    connectPublicKey: connectPublicKey,
    errorFrom: errorFrom,
    USER_REJECTED: USER_REJECTED,
    base58: { encode: encodeBase58, decode: decodeBase58 },
    codec: codec,
    url: url
  };
})(typeof window !== 'undefined' ? window : globalThis);
