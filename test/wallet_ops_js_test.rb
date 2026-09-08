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
end
