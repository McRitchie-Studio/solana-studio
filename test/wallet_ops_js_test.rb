require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

# The intent registry and the journal, exercised across simulated page deaths.
#
# WHAT MAKES THIS SUITE DIFFERENT from the two below it in the stack: those test
# pure functions over data. This one tests the thing that only means anything
# ACROSS a page destruction, so every redirect test here drives the real
# sequence — run, journal, "navigate", throw the JS world away, rebuild it, read
# the journal back out of storage, resume. A test that kept the provider object
# alive between hops would pass over a design that could never work in a browser.
#
# Storage is a real in-memory localStorage shim with the same throwing behaviour
# the browsers this runs on actually have; crypto is real tweetnacl on both
# sides. Neither is shaped from the code under test.
class WalletOpsJsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FILES = %w[wallet_transport redirect_provider wallet_journal wallet_ops].map do |f|
    File.join(ROOT, "app/assets/javascripts/solana_studio/#{f}.js")
  end
  NACL = File.join(ROOT, "node_modules/tweetnacl")

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  def setup
    # FAILS rather than skips, matching network_guard_js_test.rb. A skipped JS
    # lane is lost coverage that reads as green, and bin/release-check rejects a
    # skipped file for the same reason.
    assert self.class.node?, "node is required to run this suite (install node)"
  end

  # Same rule as node above: a MISSING DEPENDENCY IS NOT A REASON TO SKIP. These
  # are the tests that drive real crypto through the real handshake, so losing
  # them silently is losing the only coverage that would catch a wrong key or a
  # swapped nonce. CI installs it (see .github/workflows/gem-ci.yml).
  def require_nacl!
    assert Dir.exist?(NACL),
           "tweetnacl is required for the crypto round trips — run `npm ci` in the gem root"
  end

  # `storage:` "working" | "throwing" | "absent" — the three states these
  # browsers really present. A Safari private window THROWS on setItem; some
  # embedded webviews expose nothing at all.
  def run_js(script, nacl: false, storage: "working")
    shim = case storage
           when "absent" then "global.localStorage = null;"
           when "throwing"
             "global.localStorage = { getItem: function() { throw new Error('denied'); }, " \
             "setItem: function() { throw new Error('denied'); }, " \
             "removeItem: function() { throw new Error('denied'); }, length: 0, key: function() { return null; } };"
           else
             "var MEM = {};\n" \
             "global.localStorage = { getItem: function(k) { return k in MEM ? MEM[k] : null; }, " \
             "setItem: function(k, v) { MEM[k] = String(v); }, " \
             "removeItem: function(k) { delete MEM[k]; }, " \
             "get length() { return Object.keys(MEM).length; }, " \
             "key: function(i) { return Object.keys(MEM)[i]; } };"
           end

    harness = <<~JS
      global.window = global;
      #{shim}
      #{nacl ? "global.nacl = require(#{NACL.to_json});" : ""}
      #{FILES.map { |f| File.read(f) }.join("\n")}
      var S = window.SolanaStudio;
      var J = S.walletJournal, O = S.walletOps, R = S.redirectProvider, T = S.walletTransport;
      Promise.resolve((function() { #{script} })()).then(function(v) {
        console.log(JSON.stringify(v));
      }, function(e) {
        console.log(JSON.stringify({ __error: e.message }));
      });
    JS

    Tempfile.create(["wallet_ops", ".js"]) do |f|
      f.write(harness)
      f.flush
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      JSON.parse(out)
    end
  end

  # --- journal -------------------------------------------------------------

  def test_take_is_single_use_so_a_reloaded_callback_cannot_replay_a_step
    # A callback that fires twice — a reload, a back button — must not advance
    # the same step twice. Reading clears, which is the cheapest way to make
    # replay structurally impossible rather than merely unlikely.
    result = run_js(<<~JS)
      J.save({ v: 1, wallet: 'phantom', step: 'connect', startedAt: Date.now() });
      return { first: !!J.take(), second: !!J.take() };
    JS
    assert_equal({ "first" => true, "second" => false }, result)
  end

  def test_an_expired_journal_reads_as_nothing_pending
    # Abandoned trips must not be resumable later. Someone who wandered off and
    # came back should get a clean start, not a transaction they have forgotten
    # authorising.
    result = run_js(<<~JS)
      J.save({ v: 1, wallet: 'phantom', step: 'connect', startedAt: Date.now() - (J.MAX_AGE_MS + 1000) });
      return { peek: J.peek(), stillStored: !!localStorage.getItem(J.KEY) };
    JS
    assert_nil result["peek"]
    assert_equal false, result["stillStored"], "an expired journal must be cleared, not re-judged forever"
  end

  def test_a_corrupt_journal_is_dropped_rather_than_failing_every_future_read
    result = run_js(<<~JS)
      localStorage.setItem(J.KEY, '{not json');
      return { peek: J.peek(), cleared: !localStorage.getItem(J.KEY) };
    JS
    assert_nil result["peek"]
    assert_equal true, result["cleared"]
  end

  def test_storage_that_throws_degrades_to_no_pending_request
    # Safari private windows throw on every access. A callback page must render,
    # not explode.
    result = run_js(<<~JS, storage: "throwing")
      return { writable: J.writable(), saved: J.save({ v: 1, step: 'connect' }), peek: J.peek() };
    JS
    assert_equal false, result["writable"]
    assert_equal false, result["saved"]
    assert_nil result["peek"]
  end

  def test_absent_storage_is_survivable
    result = run_js("return { writable: J.writable(), peek: J.peek() };", storage: "absent")
    assert_equal false, result["writable"]
    assert_nil result["peek"]
  end

  def test_purge_removes_every_key_the_subsystem_owns
    # Hosts call this on user switch: a journal belongs to whoever started it,
    # and one that outlived a logout would offer to resume a stranger's request.
    result = run_js(<<~JS)
      localStorage.setItem(J.PREFIX + '_journal', '{}');
      localStorage.setItem(J.PREFIX + '_other', 'x');
      localStorage.setItem('unrelated', 'keep');
      J.purge();
      return { ours: localStorage.length, unrelated: localStorage.getItem('unrelated') };
    JS
    assert_equal 1, result["ours"]
    assert_equal "keep", result["unrelated"]
  end

  # --- registry contract ---------------------------------------------------

  def test_define_refuses_a_handler_missing_either_half
    result = run_js(<<~JS)
      var out = [];
      try { O.define('a', { prepare: function() {} }); out.push('accepted'); } catch (e) { out.push('refused'); }
      try { O.define('b', { complete: function() {} }); out.push('accepted'); } catch (e) { out.push('refused'); }
      return out;
    JS
    assert_equal %w[refused refused], result
  end

  def test_an_unregistered_intent_names_the_likely_cause
    # The most likely cause is a callback page that did not load the script
    # defining the intent — far from the define() that never ran, so the message
    # has to carry the diagnosis.
    result = run_js(<<~JS)
      J.save({ v: 1, wallet: 'phantom', step: 'signTransaction', startedAt: Date.now(),
               intent: { op: 'never_defined', ctx: {}, state: {} } });
      return O.resume({ nonce: 'n', data: 'd' }).then(function() { return 'resolved'; },
                                                      function(e) { return e.message; });
    JS
    assert_includes result, "never_defined"
    assert_includes result, "must load the same script"
  end

  def test_resume_with_no_pending_journal_is_not_an_error
    # A callback page can be reached with nothing pending — a stale bookmark, a
    # second tab. That is a state, not a failure.
    result = run_js("return O.resume({});")
    assert_equal({ "pending" => false }, result)
  end

  # --- inline transport ----------------------------------------------------
  #
  # A HOST'S INLINE ADAPTER, modelled the way a real one is shaped rather than
  # the way the code under test would find convenient. `deserializeTransaction`
  # hands back an OBJECT and `signTransaction` accepts only an object, exactly as
  # an injected wallet does; `serializeTransaction` puts it back to a string.
  # walletOps must therefore never see anything but base58, and the provider must
  # never see anything but an object — a fake taking a string on both sides could
  # not tell the fixed code from the bug it replaced.
  #
  # `calls` records the ORDER, which is half of what these tests assert:
  # connect must precede prepare, because prepare mints a server record and a
  # wrong wallet must not cost one.
  INLINE_ADAPTER = <<~JS
    function inlineAdapter(calls, opts) {
      opts = opts || {};
      var p = {
        transport: 'inline',
        connect: function() {
          calls.push('connect');
          // 'NONE' rather than undefined: a JS object cannot tell an explicitly
          // undefined property from an absent one, and this fake has to model a
          // wallet that resolves NOTHING as distinct from one left at its default.
          if (opts.connectResult === 'NONE') return Promise.resolve();
          return Promise.resolve(opts.connectResult === undefined ? { publicKey: opts.account || 'ACCT' } : opts.connectResult);
        },
        deserializeTransaction: function(wire) {
          if (typeof wire !== 'string') throw new Error('adapter got a non-string to deserialize');
          calls.push('deserialize:' + wire);
          return { tx: wire };
        },
        signTransaction: function(tx) {
          if (!tx || typeof tx !== 'object') throw new Error('an injected wallet signs an OBJECT, got ' + typeof tx);
          calls.push('sign:' + tx.tx);
          return Promise.resolve({ tx: 'SIGNED-' + tx.tx });
        },
        serializeTransaction: function(signed) {
          calls.push('serialize');
          return signed.tx;
        }
      };
      if (opts.providerPublicKey !== undefined) p.publicKey = opts.providerPublicKey;
      if (opts.drop) { for (var i = 0; i < opts.drop.length; i++) delete p[opts.drop[i]]; }
      return p;
    }
  JS

  def test_inline_transport_runs_connect_prepare_sign_complete_without_touching_storage
    # The desktop path must stay exactly as cheap as it was — adopting walletOps
    # is not supposed to be a rewrite of the flow that already worked. What HAS
    # changed is that it now speaks the same contract as the redirect path:
    # base58 in from prepare, base58 out to complete, with the provider owning
    # both conversions.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', {
        prepare: function(ctx) { calls.push('prepare'); return { transaction: 'TX-' + ctx.id }; },
        complete: function(ctx, r, state) { return { got: r.signedTransaction, sent: r.sendStrategy, state: state.transaction }; }
      });
      var calls = [];
      return O.run('demo', { id: 7 }, { provider: inlineAdapter(calls) }).then(function(v) {
        return { value: v, calls: calls, storageUntouched: localStorage.length === 0 };
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal "SIGNED-TX-7", result["value"]["got"],
                 "complete must be handed WIRE BYTES, not the signed object the wallet returned"
    assert_equal "app-broadcasts", result["value"]["sent"]
    assert_equal "TX-7", result["value"]["state"],
                 "prepare's own state must reach complete untouched — a deserialized copy left in it would split the transports one layer down"
    assert_equal %w[connect prepare deserialize:TX-7 sign:TX-7 serialize], result["calls"]
    assert_equal true, result["storageUntouched"]
  end

  def test_the_inline_path_connects_before_it_prepares
    # THE ORDER IS THE FEATURE, asserted on its own so a refactor that reorders
    # it goes red with a message that says why. `prepare` is a server round trip
    # that MINTS something — a prepared transaction row with a fresh blockhash —
    # so running it before the wallet has said who it is spends a real record to
    # discover the wrong account is connected. Every hand-rolled desktop call
    # site this replaces already connected first.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      var calls = [];
      O.define('demo', {
        prepare: function() { calls.push('prepare'); return { transaction: 'TX' }; },
        complete: function() { return 'done'; }
      });
      return O.run('demo', {}, { provider: inlineAdapter(calls) }).then(function() {
        return { calls: calls, connectFirst: calls.indexOf('connect') < calls.indexOf('prepare') };
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal true, result["connectFirst"],
                 "connect must precede prepare, or a wrong wallet costs a server-minted prepared transaction"
  end

  def test_the_inline_provider_must_declare_both_halves_of_the_codec
    # REFUSED BY NAME, and BEFORE THE WALLET IS TOUCHED. Both halves matter and
    # they fail at different moments: without deserializeTransaction a base58
    # string reaches the extension and throws `t.serialize is not a function`
    # from inside someone else's code; without serializeTransaction the failure
    # lands AFTER the user has approved a signature, stranding signed bytes
    # nothing can post. Checking both up front is what keeps the second one from
    # ever costing a signing prompt.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', { prepare: function() { return { transaction: 'TX' }; }, complete: function() { return 1; } });
      var out = {};
      function attempt(key, drop) {
        var calls = [];
        return O.run('demo', {}, { provider: inlineAdapter(calls, { drop: drop }) })
          .then(function() { out[key] = { message: 'ACCEPTED', calls: calls }; },
                function(e) { out[key] = { message: e.message, calls: calls }; });
      }
      return attempt('noDeserialize', ['deserializeTransaction'])
        .then(function() { return attempt('noSerialize', ['serializeTransaction']); })
        .then(function() { return out; });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_includes result["noDeserialize"]["message"], "deserializeTransaction()"
    assert_includes result["noSerialize"]["message"], "serializeTransaction()"
    result.each_value do |attempt|
      assert_includes attempt["message"], "base58 wire bytes",
                      "the refusal must say what walletOps hands over, or the reader has to guess the fix"
      assert_equal [], attempt["calls"],
                   "the codec is checked BEFORE connect — a missing half must never cost a wallet prompt"
    end
  end

  def test_a_prepare_that_returns_a_wrong_shaped_transaction_is_refused_on_both_transports
    # THE MIGRATION MISTAKE, caught at the call site rather than one page death
    # later. An intent lifted from a desktop call site returns the Transaction
    # OBJECT it used to hand straight to the wallet; a redirect journal would
    # serialise that to `{}` and the wallet would answer with its own words
    # about an invalid payload. A missing transaction is refused on the same
    # line, because every hop this file can take is a transaction hop.
    #
    # Both transports are asserted because a contract enforced on one path only
    # is exactly how the inline path drifted in the first place.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      var out = {};
      function attempt(key, prepared, redirect) {
        O.reset();
        O.define('demo', { prepare: function() { return prepared; }, complete: function() { return 1; } });
        var opts = redirect
          ? { provider: R.forWallet('phantom'), appUrl: 'https://a.test', redirectLink: 'https://a.test/cb', navigate: function() {} }
          : { provider: inlineAdapter([]) };
        return O.run('demo', {}, opts)
          .then(function() { out[key] = 'ACCEPTED'; }, function(e) { out[key] = e.message; });
      }
      return attempt('inlineObject', { transaction: { notWire: true } }, false)
        .then(function() { return attempt('redirectObject', { transaction: { notWire: true } }, true); })
        .then(function() { return attempt('inlineMissing', {}, false); })
        .then(function() { return attempt('redirectMissing', {}, true); })
        .then(function() { return attempt('inlineEmpty', { transaction: '' }, false); })
        .then(function() { return attempt('redirectEmpty', { transaction: '' }, true); })
        .then(function() { return out; });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    %w[inlineObject redirectObject].each do |key|
      assert_includes result[key], "prepared a object transaction", "#{key}: the refusal must name what it got"
      assert_includes result[key], "cannot survive a redirect", "#{key}: and why base58 is the contract"
    end
    %w[inlineMissing redirectMissing].each do |key|
      assert_includes result[key], "prepared no transaction", key
    end
    # AN EMPTY STRING IS THE TYPE-CORRECT WRONG ANSWER, so a guard written as
    # `typeof tx === 'string'` alone waves it through and the wallet answers
    # with its own words about an invalid payload. It is called out by its own
    # phrase rather than folded into the type message, because the fault is a
    # prepare that came back with nothing to sign — usually a server field read
    # under the wrong name — not a handler with the wrong type.
    %w[inlineEmpty redirectEmpty].each do |key|
      assert_includes result[key], "prepared an empty transaction", key
    end
    result.each_value { |m| assert_includes m, 'walletOps intent "demo"', "the refusal must name the intent" }
  end

  # --- redirect transport, across real page deaths -------------------------

  def test_a_cold_session_takes_connect_then_sign_and_completes
    # THE WHOLE DESIGN, end to end. Three JS worlds: the page that starts the
    # trip, the callback that lands after connect, and the callback that lands
    # after signing. Nothing crosses them except localStorage and the URL, which
    # is exactly what crosses them in a browser.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      // A stand-in wallet app: derives the shared secret from whatever public
      // key the URL carries, and answers whatever the step calls for.
      var walletPair = nacl.box.keyPair();
      function walletAnswers(url, body) {
        var u = new URL(url);
        var dappPub = u.searchParams.get('dapp_encryption_public_key');
        var shared = nacl.box.before(T.base58.decode(dappPub), walletPair.secretKey);
        var n = nacl.randomBytes(24);
        var sealed = nacl.box.after(new TextEncoder().encode(JSON.stringify(body)), n, shared);
        return {
          phantom_encryption_public_key: T.base58.encode(walletPair.publicKey),
          nonce: T.base58.encode(n),
          data: T.base58.encode(sealed),
          _shared: shared
        };
      }

      var completions = [];
      O.define('entry', {
        prepare: function(ctx) { return { transaction: 'TXB58', ptx_slug: 'ptx-' + ctx.contestId }; },
        complete: function(ctx, r, state) {
          completions.push({ contest: ctx.contestId, slug: state.ptx_slug, sig: r.signature, sent: r.sendStrategy });
          return 'entered';
        }
      });

      var urls = [];
      var opts = {
        provider: R.forWallet('phantom'),
        appUrl: 'https://a.test',
        redirectLink: 'https://a.test/cb',
        cluster: 'devnet',
        navigate: function(u) { urls.push(u); }
      };

      return O.run('entry', { contestId: 42 }, opts).then(function() {
        // --- PAGE DIES. Only localStorage survives. ---
        var connectParams = walletAnswers(urls[0], { public_key: 'USERPK', session: 'SESS' });
        return O.resume(connectParams, { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
          .then(function(afterConnect) {
            // --- PAGE DIES AGAIN. ---
            // Phantom signs only; the app broadcasts. Prove the wallet actually
            // received our session and transaction, not just that a URL existed.
            var u = new URL(urls[1]);
            var sent = JSON.parse(new TextDecoder().decode(nacl.box.open.after(
              T.base58.decode(u.searchParams.get('payload')),
              T.base58.decode(u.searchParams.get('nonce')),
              connectParams._shared
            )));
            var signParams = walletAnswers(urls[1], { transaction: 'SIGNEDTX' });
            // The wallet re-keys per call in this stand-in, so reuse the real
            // shared secret the provider will derive from the journal.
            var n2 = nacl.randomBytes(24);
            signParams.nonce = T.base58.encode(n2);
            signParams.data = T.base58.encode(nacl.box.after(
              new TextEncoder().encode(JSON.stringify({ transaction: 'SIGNEDTX' })), n2, connectParams._shared));

            return O.resume(signParams, { navigate: opts.navigate }).then(function(done) {
              return {
                hops: urls.length,
                firstIsConnect: urls[0].indexOf('/ul/v1/connect?') !== -1,
                secondIsSign: urls[1].indexOf('/ul/v1/signTransaction?') !== -1,
                sentSession: sent.session,
                sentTransaction: sent.transaction,
                afterConnectSuspended: !!afterConnect.suspended,
                done: done.done,
                value: done.value,
                completions: completions,
                journalCleared: !localStorage.getItem(J.KEY)
              };
            });
          });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal 2, result["hops"], "a cold session is connect then sign"
    assert_equal true, result["firstIsConnect"]
    assert_equal true, result["secondIsSign"], "Phantom must sign only — its send-side deeplink is deprecated"
    assert_equal "SESS", result["sentSession"], "the session must survive the page death"
    assert_equal "TXB58", result["sentTransaction"]
    assert_equal true, result["afterConnectSuspended"]
    assert_equal true, result["done"]
    assert_equal "entered", result["value"]
    assert_equal [{ "contest" => 42, "slug" => "ptx-42", "sig" => nil, "sent" => "app-broadcasts" }],
                 result["completions"], "ctx and prepare state must both survive both page deaths"
    assert_equal true, result["journalCleared"]
  end

  def test_a_wallet_that_broadcasts_reports_a_signature_instead
    # Solflare and Backpack keep signAndSendTransaction, so `complete` is handed
    # a signature and no signed transaction. A handler branches on sendStrategy;
    # getting this backwards would double-broadcast or never broadcast.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      var walletPair = nacl.box.keyPair();
      O.define('entry', {
        prepare: function() { return { transaction: 'TXB58' }; },
        complete: function(ctx, r) { return { sig: r.signature, signed: r.signedTransaction, sent: r.sendStrategy }; }
      });
      var urls = [];
      var opts = { provider: R.forWallet('solflare'), appUrl: 'https://a.test',
                   redirectLink: 'https://a.test/cb', navigate: function(u) { urls.push(u); } };

      return O.run('entry', {}, opts).then(function() {
        var u0 = new URL(urls[0]);
        var shared = nacl.box.before(T.base58.decode(u0.searchParams.get('dapp_encryption_public_key')), walletPair.secretKey);
        function seal(body) {
          var n = nacl.randomBytes(24);
          return { solflare_encryption_public_key: T.base58.encode(walletPair.publicKey),
                   nonce: T.base58.encode(n),
                   data: T.base58.encode(nacl.box.after(new TextEncoder().encode(JSON.stringify(body)), n, shared)) };
        }
        return O.resume(seal({ public_key: 'PK', session: 'SESS' }),
                        { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
          .then(function() {
            return O.resume(seal({ signature: 'SIGX' }), { navigate: opts.navigate }).then(function(done) {
              return { secondHop: urls[1].indexOf('/ul/v1/signAndSendTransaction?') !== -1, value: done.value };
            });
          });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal true, result["secondHop"], "Solflare must use signAndSendTransaction"
    assert_equal "SIGX", result["value"]["sig"]
    assert_nil result["value"]["signed"]
    assert_equal "wallet-broadcasts", result["value"]["sent"]
  end

  def test_a_redirect_is_refused_when_the_journal_cannot_be_written
    # Better to refuse before leaving the page than to strand the user inside
    # their wallet app with a callback that will find nothing pending.
    result = run_js(<<~JS, storage: "throwing")
      O.define('x', { prepare: function() { return { transaction: 'T' }; }, complete: function() { return 1; } });
      return O.run('x', {}, { provider: R.forWallet('phantom'), appUrl: 'https://a.test',
                              redirectLink: 'https://a.test/cb', navigate: function() {} })
        .then(function() { return 'started'; }, function(e) { return e.message; });
    JS
    assert_includes result, "cannot store a pending wallet request"
    assert_includes result, "wallet app"
  end

  # --- sign-only intents ---------------------------------------------------
  #
  # WHY THIS SECTION EXISTS AT ALL. A co-signed transaction — turf-monster's
  # contest entry is one — arrives from the server PARTIALLY signed, with the
  # admin signer slot deliberately empty. The user's wallet signs its own slot
  # and the app POSTs the signed bytes back for the server to cosign and
  # broadcast. Hand that same transaction to a wallet's own broadcaster and two
  # things go wrong at once: the chain rejects it for a missing required
  # signature, AND the signed bytes never come back to the app, so there is
  # nothing to retry with. Capability alone cannot see any of that, which is why
  # the intent gets to declare it.
  #
  # Every test below drives the REAL signing hop and reads the METHOD SEGMENT
  # out of the deeplink the wallet would have been sent to. That is the only
  # observable that distinguishes the two branches, and it is the same string a
  # wallet app would dispatch on.

  # The supplied-session path: journal fields a connect hop would have produced,
  # handed in directly, so one script can drive all three wallets without three
  # crypto round trips. The signing hop itself is unchanged — it is reached
  # through beginSigning exactly as a warm session reaches it in production.
  SIGN_HOP_HARNESS = <<~JS
    var WALLETS = ['phantom', 'solflare', 'backpack'];

    // The last path segment, which is the deeplink's method name. Written with
    // split/substring rather than a regex ON PURPOSE: this string is embedded in
    // a Ruby heredoc that processes backslash escapes, so a regex here would
    // arrive at node quietly mangled.
    function methodOf(url) {
      var path = String(url).split('?')[0];
      return path.substring(path.lastIndexOf('/') + 1);
    }

    function hop(walletKey, declared) {
      O.reset();
      var handler = {
        prepare: function() { return { transaction: 'TXB58' }; },
        complete: function() { return 'done'; }
      };
      if (declared !== undefined) handler.signOnly = declared;
      O.define('op', handler);

      var dapp = nacl.box.keyPair(), wal = nacl.box.keyPair();
      var seen = null;
      return O.run('op', {}, {
        provider: R.forWallet(walletKey),
        redirectLink: 'https://a.test/cb',
        navigate: function(u) { seen = u; },
        session: {
          dappSecretKey: T.base58.encode(dapp.secretKey),
          dappPublicKey: T.base58.encode(dapp.publicKey),
          walletPublicKey: T.base58.encode(wal.publicKey),
          session: 'SESS'
        }
      }).then(function() { return methodOf(seen); });
    }

    function eachWallet(declared, out) {
      return WALLETS.reduce(function(chain, w) {
        return chain.then(function() {
          return hop(w, declared).then(function(m) { out[w] = m; });
        });
      }, Promise.resolve());
    }
  JS

  def test_a_sign_only_intent_reaches_signtransaction_on_every_wallet
    # ACCEPTANCE: "co-signed flows never reach signAndSendTransaction". Solflare
    # and Backpack both HAVE the send-side deeplink and would have taken it
    # before this change; Phantom is here because a wallet that never had it
    # must not become a special case that quietly certifies the old branch.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      #{SIGN_HOP_HARNESS}
      var out = {};
      return eachWallet(true, out).then(function() { return out; });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    %w[phantom solflare backpack].each do |wallet|
      assert_equal "signTransaction", result[wallet],
                   "#{wallet}: a declared sign-only intent must never reach the wallet's broadcaster"
    end
  end

  def test_an_undeclared_intent_keeps_the_send_side_default_on_every_wallet
    # ACCEPTANCE: "existing send-side intents keep current behaviour". This is
    # the OTHER branch, and it is the one a careless fix breaks — routing every
    # intent to signTransaction would satisfy the test above and silently strip
    # Solflare and Backpack of the hop they are supposed to take.
    #
    # `false` is asserted alongside `undefined` because they are different
    # inputs reaching the same branch: one is "never declared", the other is
    # "declared not to need it", and a truthiness bug would separate them.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      #{SIGN_HOP_HARNESS}
      var out = { undeclared: {}, declaredFalse: {} };
      return eachWallet(undefined, out.undeclared).then(function() {
        return eachWallet(false, out.declaredFalse).then(function() { return out; });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    expected = {
      "phantom" => "signTransaction",
      "solflare" => "signAndSendTransaction",
      "backpack" => "signAndSendTransaction"
    }
    assert_equal expected, result["undeclared"],
                 "an intent that declares nothing must be routed exactly as it was before signOnly existed"
    assert_equal expected, result["declaredFalse"],
                 "signOnly: false is a declaration that the wallet MAY broadcast, not a truthiness accident"
  end

  def test_a_sign_only_intent_survives_the_page_death_and_completes_app_broadcasts
    # The full trip on the wallet that WOULD have broadcast. Two page deaths,
    # nothing crossing them but localStorage and the URL — so this fails if the
    # declaration is decided on the first page and then forgotten, which is the
    # only way a fix that passes the matrix above can still be wrong in a
    # browser. Driven to completion because the branch is not the point on its
    # own: `complete` must be handed the SIGNED BYTES the server needs.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      var walletPair = nacl.box.keyPair();
      O.define('entry', {
        prepare: function(ctx) { return { transaction: 'TXB58', ptx_slug: 'ptx-' + ctx.contestId }; },
        complete: function(ctx, r, state) {
          return { sig: r.signature, signed: r.signedTransaction, sent: r.sendStrategy, slug: state.ptx_slug };
        },
        signOnly: true
      });

      var urls = [];
      var opts = { provider: R.forWallet('solflare'), appUrl: 'https://a.test',
                   redirectLink: 'https://a.test/cb', navigate: function(u) { urls.push(u); } };

      return O.run('entry', { contestId: 42 }, opts).then(function() {
        // --- PAGE DIES. Only localStorage survives. ---
        var u0 = new URL(urls[0]);
        var shared = nacl.box.before(
          T.base58.decode(u0.searchParams.get('dapp_encryption_public_key')), walletPair.secretKey);
        function seal(body) {
          var n = nacl.randomBytes(24);
          return { solflare_encryption_public_key: T.base58.encode(walletPair.publicKey),
                   nonce: T.base58.encode(n),
                   data: T.base58.encode(nacl.box.after(
                     new TextEncoder().encode(JSON.stringify(body)), n, shared)) };
        }
        return O.resume(seal({ public_key: 'PK', session: 'SESS' }),
                        { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
          .then(function() {
            // --- PAGE DIES AGAIN. The wallet answers the hop it was sent to. ---
            var journalSaid = JSON.parse(localStorage.getItem(J.KEY)).intent.signOnly;
            return O.resume(seal({ transaction: 'SIGNEDTX' }), { navigate: opts.navigate })
              .then(function(done) {
                return {
                  secondHop: urls[1],
                  journalSaid: journalSaid,
                  value: done.value
                };
              });
          });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_includes result["secondHop"], "/ul/v1/signTransaction?",
                    "Solflare CAN broadcast, and a co-signed entry must still send it to signTransaction"
    refute_includes result["secondHop"], "signAndSendTransaction"
    assert_equal true, result["journalSaid"],
                 "the declaration must be written into the journal, which is the only thing that crosses a page death"
    assert_equal "SIGNEDTX", result["value"]["signed"],
                 "the server cosigns these bytes — a flow that returns only a signature has nothing to POST"
    assert_nil result["value"]["sig"]
    assert_equal "app-broadcasts", result["value"]["sent"]
    assert_equal "ptx-42", result["value"]["slug"]
  end

  def test_the_sign_only_declaration_holds_when_the_callback_page_lacks_the_intent
    # WHY THE DECLARATION LIVES IN THE JOURNAL rather than being looked up from
    # the handler at the hop.
    #
    # The connect callback is a DIFFERENT DOCUMENT, and `resume` deliberately
    # does not require a handler to advance from connect to signing — only the
    # final completion needs one. So a page that has not (yet) loaded the script
    # defining this intent still takes the signing hop, and a lookup there would
    # come back empty and fall through to the send-side default: precisely the
    # branch a co-signed transaction must never take, reached silently.
    #
    # The registry is cleared between the run and the connect callback to stand
    # that page up honestly, then restored for the completion that genuinely
    # requires it.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      var walletPair = nacl.box.keyPair();
      var handler = {
        prepare: function() { return { transaction: 'TXB58' }; },
        complete: function(ctx, r) { return { sent: r.sendStrategy }; },
        signOnly: true
      };
      O.define('entry', handler);

      var urls = [];
      var opts = { provider: R.forWallet('backpack'), appUrl: 'https://a.test',
                   redirectLink: 'https://a.test/cb', navigate: function(u) { urls.push(u); } };

      return O.run('entry', {}, opts).then(function() {
        // --- PAGE DIES, and the callback document never loaded the script
        //     that defined this intent. ---
        O.reset();
        var u0 = new URL(urls[0]);
        var shared = nacl.box.before(
          T.base58.decode(u0.searchParams.get('dapp_encryption_public_key')), walletPair.secretKey);
        function seal(body) {
          var n = nacl.randomBytes(24);
          return { wallet_encryption_public_key: T.base58.encode(walletPair.publicKey),
                   nonce: T.base58.encode(n),
                   data: T.base58.encode(nacl.box.after(
                     new TextEncoder().encode(JSON.stringify(body)), n, shared)) };
        }
        return O.resume(seal({ public_key: 'PK', session: 'SESS' }),
                        { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
          .then(function() {
            return { hop: urls[1], registered: O.names() };
          });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal [], result["registered"],
                 "the point of this test is a callback page with NO intent registered"
    assert_includes result["hop"], "/ul/v1/signTransaction?",
                    "the journal, not a handler lookup, must decide the hop on a page that never ran define()"
    refute_includes result["hop"], "signAndSendTransaction"
  end

  def test_define_refuses_a_non_boolean_sign_only
    # Every wrong answer here fails in the dangerous direction, and neither is
    # visible at the call site: read as truthy, a typo'd 'false' would strip a
    # wallet of its broadcaster; read strictly, a typo'd 'true' sends a
    # co-signed transaction to one. So it is a boolean or it is refused.
    result = run_js(<<~JS)
      var base = { prepare: function() { return {}; }, complete: function() { return 1; } };
      function attempt(value) {
        var h = { prepare: base.prepare, complete: base.complete, signOnly: value };
        try { O.define('x', h); return 'accepted'; } catch (e) { return e.message; }
      }
      return { string: attempt('true'), number: attempt(1), nul: attempt(null),
               ok_true: attempt(true), ok_false: attempt(false), absent: (function() {
                 try { O.define('y', { prepare: base.prepare, complete: base.complete }); return 'accepted'; }
                 catch (e) { return e.message; }
               })() };
    JS
    assert_includes result["string"], "signOnly must be true or false"
    assert_includes result["string"], "string", "the message must name what it actually got"
    assert_includes result["number"], "signOnly must be true or false"
    assert_includes result["nul"], "signOnly must be true or false"
    assert_equal "accepted", result["ok_true"]
    assert_equal "accepted", result["ok_false"]
    assert_equal "accepted", result["absent"], "the option stays optional — an intent need not declare anything"
  end

  # --- one call site, both transports --------------------------------------

  # A stand-in wallet app for the redirect leg: derives the shared secret from
  # whatever public key the URL carries and answers whatever the step calls for.
  # Kept as one harness so the two-transport tests below drive the REAL crypto
  # handshake rather than a stub shaped from the code under test.
  REDIRECT_WALLET = <<~JS
    function redirectWorld(walletKey) {
      var walletPair = nacl.box.keyPair();
      var shared = null;
      return {
        urls: [],
        // The connect answer, which is also where the shared secret is fixed.
        connectAnswer: function(url, body) {
          var u = new URL(url);
          shared = nacl.box.before(T.base58.decode(u.searchParams.get('dapp_encryption_public_key')), walletPair.secretKey);
          return this.seal(walletKey, body);
        },
        seal: function(wk, body) {
          var n = nacl.randomBytes(24);
          var out = { nonce: T.base58.encode(n),
                      data: T.base58.encode(nacl.box.after(new TextEncoder().encode(JSON.stringify(body)), n, shared)) };
          out[wk === 'phantom' ? 'phantom_encryption_public_key'
              : wk === 'solflare' ? 'solflare_encryption_public_key'
              : 'wallet_encryption_public_key'] = T.base58.encode(walletPair.publicKey);
          return out;
        }
      };
    }
  JS

  def test_both_transports_hand_complete_the_same_result_and_state_shapes
    # THE ACCEPTANCE CRITERION, and the only test in this file that can see it:
    # ONE registered intent, run over BOTH transports, with `complete` recording
    # what it was actually handed. Before this change the inline path gave it a
    # signed Transaction OBJECT and the redirect path gave it a base58 STRING,
    # so a call site had to branch on which — and every consumer kept two.
    #
    # The state half matters just as much as the result half: `prepare`'s own
    # return value must reach `complete` untouched on both paths, or a handler
    # that reads `state.transaction` gets a different type per transport one
    # layer below the one just fixed.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      #{INLINE_ADAPTER}
      #{REDIRECT_WALLET}
      var seen = {};
      O.define('entry', {
        prepare: function(ctx) { return { transaction: 'TXB58', ptx_slug: 'ptx-' + ctx.id }; },
        complete: function(ctx, r, state) {
          seen[ctx.via] = {
            signedType: typeof r.signedTransaction,
            signed: r.signedTransaction,
            stateType: typeof state.transaction,
            state: state.transaction,
            slug: state.ptx_slug
          };
          return 'ok';
        },
        signOnly: true
      });

      return O.run('entry', { id: 7, via: 'inline' }, { provider: inlineAdapter([]) }).then(function() {
        var world = redirectWorld('phantom');
        var opts = { provider: R.forWallet('phantom'), appUrl: 'https://a.test',
                     redirectLink: 'https://a.test/cb', navigate: function(u) { world.urls.push(u); } };
        return O.run('entry', { id: 7, via: 'redirect' }, opts).then(function() {
          // --- PAGE DIES ---
          return O.resume(world.connectAnswer(world.urls[0], { public_key: 'PK', session: 'SESS' }),
                          { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
            .then(function() {
              // --- PAGE DIES AGAIN ---
              return O.resume(world.seal('phantom', { transaction: 'SIGNED-TXB58' }), { navigate: opts.navigate })
                .then(function() { return seen; });
            });
        });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal "string", result["inline"]["signedType"],
                 "the inline path must hand complete WIRE BYTES, not the wallet's signed object"
    assert_equal "string", result["redirect"]["signedType"]
    assert_equal "SIGNED-TXB58", result["inline"]["signed"]
    assert_equal "SIGNED-TXB58", result["redirect"]["signed"]
    assert_equal result["inline"]["state"], result["redirect"]["state"],
                 "prepare's transaction must reach complete identically on both transports"
    assert_equal "TXB58", result["inline"]["state"]
    assert_equal "ptx-7", result["inline"]["slug"]
    assert_equal "ptx-7", result["redirect"]["slug"]
  end

  # --- the expected account ------------------------------------------------
  #
  # WHAT THIS IS AND IS NOT. It is a UX guard: the ownership proof is ON-CHAIN —
  # Anchor rejects a transaction whose signer does not match the entry PDA's
  # owner — and nothing here changes that. What the declaration buys is a
  # sentence a user can act on instead of a program error, and, on the inline
  # transport only, a server-minted prepared transaction that is never wasted.

  LINKED   = "GkxHc1Bv7pQm4RtyVn2ZcAeD8sWfLuJp3NoXaTgYkQrM"
  STRANGER = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"

  def test_a_declared_expected_account_refuses_a_different_wallet_before_prepare
    # THE WHOLE POINT OF CONNECTING FIRST. `prepare` must not have run: it is a
    # server round trip that mints a prepared-transaction row, and spending one
    # to discover the wrong account is connected is the cost this exists to
    # avoid. Asserted on `calls`, which is the only observable that can tell the
    # refusal apart from a refusal one step later.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      var calls = [];
      O.define('demo', {
        prepare: function() { calls.push('prepare'); return { transaction: 'TX' }; },
        complete: function() { return 'done'; }
      });
      return O.run('demo', {}, {
        provider: inlineAdapter(calls, { account: '#{STRANGER}' }),
        expectedAccount: '#{LINKED}'
      }).then(function() { return { outcome: 'ACCEPTED', calls: calls }; },
              function(e) {
                return { outcome: e.message, calls: calls, wrongAccount: e.wrongAccount,
                         expected: e.expected, connected: e.connected };
              });
    JS
    assert_includes result["outcome"], "Wrong wallet"
    assert_includes result["outcome"], LINKED[0, 4], "the message must name the linked account"
    assert_includes result["outcome"], LINKED[-4..]
    assert_includes result["outcome"], STRANGER[0, 4]
    refute_includes result["calls"], "prepare",
                    "the refusal must land BEFORE prepare, or a wrong wallet still costs a prepared transaction"
    assert_equal ["connect"], result["calls"]
    assert_equal true, result["wrongAccount"], "a host composing its own sentence needs to recognise this error"
    assert_equal LINKED, result["expected"], "the FULL addresses ride on the error; only the message is truncated"
    assert_equal STRANGER, result["connected"]
  end

  def test_the_matching_wallet_runs_through_untouched
    # The other branch, and the one a careless guard breaks: refusing everything
    # would satisfy the test above and take every correct entry with it.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      var calls = [];
      O.define('demo', {
        prepare: function() { return { transaction: 'TX' }; },
        complete: function(ctx, r) { return r.signedTransaction; }
      });
      return O.run('demo', {}, {
        provider: inlineAdapter(calls, { account: '#{LINKED}' }),
        expectedAccount: '#{LINKED}'
      });
    JS
    assert_equal "SIGNED-TX", result
  end

  def test_the_connected_account_is_read_off_the_provider_when_connect_resolves_nothing
    # Not every injected wallet resolves connect() with the account — some set
    # `provider.publicKey` and resolve undefined. A guard that only looked at
    # the resolve value would refuse those wallets by NAME, telling a user with
    # the right wallet that their wallet did not say who it was.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', {
        prepare: function() { return { transaction: 'TX' }; },
        complete: function(ctx, r) { return r.signedTransaction; }
      });
      return O.run('demo', {}, {
        provider: inlineAdapter([], { connectResult: 'NONE', providerPublicKey: '#{LINKED}' }),
        expectedAccount: '#{LINKED}'
      }).then(function(v) { return v; }, function(e) { return e.message; });
    JS
    assert_equal "SIGNED-TX", result
  end

  def test_an_account_the_wallet_never_reported_is_refused_rather_than_skipped
    # SILENTLY SKIPPING THE CHECK IS THE ONE UNACCEPTABLE ANSWER. A caller that
    # declared an expected account asked a question; answering "I could not
    # tell" by proceeding is how a guard reads as present and is not.
    #
    # The `[object Object]` case is here alongside the absent one because it is
    # the more dangerous shape: stringifying an object with no meaningful
    # toString produces a value that is not empty, would compare unequal, and
    # would put a WRONG WALLET sentence in front of someone whose wallet is
    # fine — a worse outcome than saying nothing could be read.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', { prepare: function() { return { transaction: 'TX' }; }, complete: function() { return 1; } });
      var out = {};
      function attempt(key, opts) {
        return O.run('demo', {}, { provider: inlineAdapter([], opts), expectedAccount: '#{LINKED}' })
          .then(function() { out[key] = 'ACCEPTED'; }, function(e) { out[key] = e.message; });
      }
      return attempt('nothingReported', { connectResult: {} })
        .then(function() { return attempt('unreadable', { connectResult: { publicKey: { nope: true } } }); })
        .then(function() { return out; });
    JS
    assert_includes result["nothingReported"], "did not say which account"
    assert_includes result["unreadable"], "did not say which account",
                    "an unreadable account must read as unknown, never as a wrong wallet"
    refute_includes result["unreadable"], "Wrong wallet"
  end

  def test_run_refuses_a_non_string_expected_account
    # REFUSED RATHER THAN STRINGIFIED, and the reason is transport-specific: a
    # solanaWeb3.PublicKey would String() correctly on the inline path and be
    # written into the journal as `{}` on the redirect one — matching on a
    # desktop and refusing every mobile trip with a wrong-wallet sentence naming
    # an account nobody has. The two transports disagreeing about a value is the
    # failure this whole change exists to remove.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', { prepare: function() { return { transaction: 'TX' }; }, complete: function() { return 1; } });
      var out = {};
      function attempt(key, value) {
        var o = { provider: inlineAdapter([], { account: '#{LINKED}' }) };
        if (value !== 'OMIT') o.expectedAccount = value;
        return O.run('demo', {}, o).then(function() { out[key] = 'ACCEPTED'; }, function(e) { out[key] = e.message; });
      }
      return attempt('publicKeyObject', { toString: function() { return '#{LINKED}'; } })
        .then(function() { return attempt('omitted', 'OMIT'); })
        .then(function() { return attempt('undefinedValue', undefined); })
        .then(function() { return attempt('nullValue', null); })
        .then(function() { return out; });
    JS
    assert_includes result["publicKeyObject"], "must be a base58 address string"
    assert_includes result["publicKeyObject"], "toString()", "the refusal must name the fix"
    assert_equal "ACCEPTED", result["omitted"], "the option stays optional"
    assert_equal "ACCEPTED", result["undefinedValue"]
    assert_equal "ACCEPTED", result["nullValue"], "an explicit null is 'nothing to check', not a type error"
  end

  def test_the_expected_account_refuses_on_the_connect_callback_before_any_signing_hop
    # THE REDIRECT HALF, driven across a real page death. The refusal has to land
    # on the connect callback: it is the one moment this transport learns who
    # connected, and the last one before the wallet is asked for a signature.
    #
    # `hops` is what proves it. A refusal that arrived after the second
    # navigation would still reject the promise — and would already have sent
    # the user back into their wallet to approve a transaction that could never
    # have been accepted.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      #{REDIRECT_WALLET}
      O.define('entry', {
        prepare: function() { return { transaction: 'TXB58' }; },
        complete: function() { return 'entered'; },
        signOnly: true
      });
      var world = redirectWorld('phantom');
      var opts = { provider: R.forWallet('phantom'), appUrl: 'https://a.test',
                   redirectLink: 'https://a.test/cb', navigate: function(u) { world.urls.push(u); } };

      return O.run('entry', {}, { provider: opts.provider, appUrl: opts.appUrl,
                                  redirectLink: opts.redirectLink, navigate: opts.navigate,
                                  expectedAccount: '#{LINKED}' }).then(function() {
        var journalled = JSON.parse(localStorage.getItem(J.KEY)).intent.expectedAccount;
        // --- PAGE DIES. Only localStorage survives. ---
        return O.resume(world.connectAnswer(world.urls[0], { public_key: '#{STRANGER}', session: 'SESS' }),
                        { redirectLink: 'https://a.test/cb', navigate: opts.navigate })
          .then(function() { return { outcome: 'ADVANCED', hops: world.urls.length }; },
                function(e) {
                  return { outcome: e.message, hops: world.urls.length, journalled: journalled,
                           wrongAccount: e.wrongAccount, connected: e.connected,
                           journalCleared: !localStorage.getItem(J.KEY) };
                });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_includes result["outcome"], "Wrong wallet"
    assert_equal 1, result["hops"],
                 "the connect hop is the only navigation that may happen — a signing hop would prompt the user for a signature that cannot be used"
    assert_equal LINKED, result["journalled"],
                 "the declaration must be written into the journal, which is the only thing that crosses a page death"
    assert_equal true, result["wrongAccount"]
    assert_equal STRANGER, result["connected"]
    assert_equal true, result["journalCleared"],
                 "resume takes the journal before it advances, so a refusal leaves no half-trip to resume"
  end

  def test_the_expected_account_holds_on_a_callback_page_that_never_registered_the_intent
    # WHY THIS IS A DECLARED VALUE AND NOT A POST-CONNECT HOOK, which is the
    # obvious design and the wrong one.
    #
    # The connect callback is a DIFFERENT DOCUMENT — in this ecosystem it is
    # studio-engine's wallet callback view, which knows nothing about any
    # consumer's flows — and `resume` deliberately does not require a handler to
    # advance from connect to signing. A hook would therefore be looked up on
    # exactly the hop it exists to guard, come back empty, and be skipped in
    # silence. A string in the journal cannot be skipped: there is nothing to
    # look up.
    #
    # The registry is cleared between the run and the callback to stand that
    # page up honestly.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      #{REDIRECT_WALLET}
      O.define('entry', {
        prepare: function() { return { transaction: 'TXB58' }; },
        complete: function() { return 'entered'; }
      });
      var world = redirectWorld('solflare');
      var nav = function(u) { world.urls.push(u); };
      return O.run('entry', {}, { provider: R.forWallet('solflare'), appUrl: 'https://a.test',
                                  redirectLink: 'https://a.test/cb', navigate: nav,
                                  expectedAccount: '#{LINKED}' }).then(function() {
        // --- PAGE DIES, and the callback document never loaded the script
        //     that defined this intent. ---
        O.reset();
        return O.resume(world.connectAnswer(world.urls[0], { public_key: '#{STRANGER}', session: 'SESS' }),
                        { redirectLink: 'https://a.test/cb', navigate: nav })
          .then(function() { return { outcome: 'ADVANCED', hops: world.urls.length, registered: O.names() }; },
                function(e) { return { outcome: e.message, hops: world.urls.length, registered: O.names() }; });
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal [], result["registered"],
                 "the point of this test is a callback page with NO intent registered"
    assert_includes result["outcome"], "Wrong wallet"
    assert_equal 1, result["hops"], "a page with no handler must still refuse, not fall through to the signing hop"
  end

  def test_an_undeclared_expected_account_leaves_the_journal_as_it_was
    # The same rule signOnly follows, and for the same reason: an intent that
    # declares nothing must write a journal byte-identical to the one it wrote
    # before this option existed, so no reader's expectations change and
    # JOURNAL_VERSION does not have to move — which would strand every trip
    # already in flight.
    require_nacl!
    result = run_js(<<~JS, nacl: true)
      O.define('entry', { prepare: function() { return { transaction: 'TXB58' }; }, complete: function() { return 1; } });
      return O.run('entry', { id: 1 }, {
        provider: R.forWallet('phantom'), appUrl: 'https://a.test',
        redirectLink: 'https://a.test/cb', navigate: function() {}
      }).then(function() {
        var intent = JSON.parse(localStorage.getItem(J.KEY)).intent;
        return { keys: Object.keys(intent).sort(), has: ('expectedAccount' in intent) };
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal false, result["has"], "an undeclared account must not appear in the journal at all"
    assert_equal %w[ctx op state], result["keys"]
  end

  def test_the_inline_transport_is_unchanged_by_a_sign_only_declaration
    # Inline was ALREADY sign-only — it calls provider.signTransaction and
    # nothing else — so the declaration must be a no-op here rather than a
    # second code path. Asserted rather than assumed, because "it cannot
    # possibly affect that" is how the desktop flow gets broken by a mobile fix.
    result = run_js(<<~JS)
      #{INLINE_ADAPTER}
      O.define('demo', {
        prepare: function(ctx) { return { transaction: 'TX-' + ctx.id }; },
        complete: function(ctx, r) { return { got: r.signedTransaction, sent: r.sendStrategy }; },
        signOnly: true
      });
      var calls = [];
      var inline = inlineAdapter(calls);
      inline.signAndSendTransaction = function(tx) { calls.push('sendside:' + tx.tx); return Promise.resolve('SIG'); };
      return O.run('demo', { id: 7 }, { provider: inline }).then(function(v) {
        return { value: v, calls: calls, storageUntouched: localStorage.length === 0 };
      });
    JS
    refute result["__error"], "flow errored: #{result['__error']}"
    assert_equal "SIGNED-TX-7", result["value"]["got"]
    assert_equal "app-broadcasts", result["value"]["sent"]
    assert_equal %w[connect deserialize:TX-7 sign:TX-7 serialize], result["calls"],
                 "the inline provider's send-side method must not be reached, declared or not"
    assert_equal true, result["storageUntouched"]
  end
end
