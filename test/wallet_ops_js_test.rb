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

  def test_inline_transport_runs_prepare_sign_complete_without_touching_storage
    # The desktop path must stay exactly as cheap as it was — adopting walletOps
    # is not supposed to be a rewrite of the flow that already worked.
    result = run_js(<<~JS)
      O.define('demo', {
        prepare: function(ctx) { return { transaction: 'TX-' + ctx.id }; },
        complete: function(ctx, r, state) { return { got: r.signedTransaction, sent: r.sendStrategy, state: state.transaction }; }
      });
      var calls = [];
      var inline = {
        transport: 'inline',
        connect: function() { calls.push('connect'); return Promise.resolve({}); },
        signTransaction: function(tx) { calls.push('sign:' + tx); return Promise.resolve('SIGNED-' + tx); }
      };
      return O.run('demo', { id: 7 }, { provider: inline }).then(function(v) {
        return { value: v, calls: calls, storageUntouched: localStorage.length === 0 };
      });
    JS
    assert_equal "SIGNED-TX-7", result["value"]["got"]
    assert_equal "app-broadcasts", result["value"]["sent"]
    assert_equal ["connect", "sign:TX-7"], result["calls"]
    assert_equal true, result["storageUntouched"]
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

  def test_the_inline_transport_is_unchanged_by_a_sign_only_declaration
    # Inline was ALREADY sign-only — it calls provider.signTransaction and
    # nothing else — so the declaration must be a no-op here rather than a
    # second code path. Asserted rather than assumed, because "it cannot
    # possibly affect that" is how the desktop flow gets broken by a mobile fix.
    result = run_js(<<~JS)
      O.define('demo', {
        prepare: function(ctx) { return { transaction: 'TX-' + ctx.id }; },
        complete: function(ctx, r) { return { got: r.signedTransaction, sent: r.sendStrategy }; },
        signOnly: true
      });
      var calls = [];
      var inline = {
        transport: 'inline',
        connect: function() { calls.push('connect'); return Promise.resolve({}); },
        signTransaction: function(tx) { calls.push('sign:' + tx); return Promise.resolve('SIGNED-' + tx); },
        signAndSendTransaction: function(tx) { calls.push('sendside:' + tx); return Promise.resolve('SIG'); }
      };
      return O.run('demo', { id: 7 }, { provider: inline }).then(function(v) {
        return { value: v, calls: calls, storageUntouched: localStorage.length === 0 };
      });
    JS
    assert_equal "SIGNED-TX-7", result["value"]["got"]
    assert_equal "app-broadcasts", result["value"]["sent"]
    assert_equal ["connect", "sign:TX-7"], result["calls"],
                 "the inline provider's send-side method must not be reached, declared or not"
    assert_equal true, result["storageUntouched"]
  end
end
