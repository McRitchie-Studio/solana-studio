require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

# SolanaStudio.walletIdentity, executed under node against fake wallets.
#
# WHAT THE FAKES ARE MODELLED ON, so nobody reads them as shaped from the code
# under test:
#
#   · the legacy provider is Phantom's injected `window.phantom.solana`: a live
#     `publicKey`, `on`/`off`, and `accountChanged` (a key, or null on a lock,
#     a disconnect, or a switch to an account the site was never approved for),
#     `connect`, `disconnect`, and `connect({ onlyIfTrusted: true })`, which
#     rejects for a site the wallet does not trust.
#   · the Wallet Standard wallet follows @wallet-standard/base: `accounts` is the
#     wallet's own live view, `standard:events` `on("change", fn)` returns its
#     unsubscribe function and passes only the properties that changed, and
#     `standard:connect` takes `{ silent: true }`.
#   · the StudioSession stub implements the identity-source contract written in
#     studio-engine docs/SESSION_DRIFT.md ("Identity sources" and "Holds"):
#     report(undefined) changes nothing, report(null) observes nobody, an unbound
#     source never mismatches, a mismatch fires session:mismatch unless a hold
#     covers the source, and reporting the bound identity again resolves it.
#
# Each test gets a fresh node process: fresh window, fresh document, and manual
# timers, so a discovery window is advanced deterministically rather than slept.
class WalletIdentityJsTest < Minitest::Test
  SOURCE = File.expand_path("../app/assets/javascripts/solana_studio/wallet_identity.js", __dir__)

  A = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU".freeze
  B = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM".freeze
  C = "HN7cABqLq46Es1jh92dQQisAq662SmxELLLsHHe4YWrH".freeze

  HARNESS = <<~JS.freeze
    global.window = global;

    function makeTarget(target) {
      var map = {};
      target.addEventListener = function (type, fn) { (map[type] = map[type] || []).push(fn); };
      target.removeEventListener = function (type, fn) {
        map[type] = (map[type] || []).filter(function (f) { return f !== fn; });
      };
      target.dispatch = function (type) {
        (map[type] || []).slice().forEach(function (fn) { fn({ type: type }); });
      };
      target.listenerCount = function (type) { return (map[type] || []).length; };
      return target;
    }
    makeTarget(global);
    global.document = makeTarget({ visibilityState: "visible" });

    // Manual timers: a discovery window is advanced, never slept.
    var TIMERS = { now: 0, seq: 0, queue: [] };
    global.setTimeout = function (fn, ms) {
      var id = ++TIMERS.seq;
      TIMERS.queue.push({ id: id, at: TIMERS.now + (ms || 0), fn: fn });
      return id;
    };
    global.clearTimeout = function (id) {
      TIMERS.queue = TIMERS.queue.filter(function (t) { return t.id !== id; });
    };
    function advance(ms) {
      var end = TIMERS.now + ms;
      for (;;) {
        TIMERS.queue.sort(function (a, b) { return a.at - b.at || a.id - b.id; });
        var next = TIMERS.queue[0];
        if (!next || next.at > end) break;
        TIMERS.queue.shift();
        TIMERS.now = next.at;
        next.fn();
      }
      TIMERS.now = end;
    }
    function pendingTimers() { return TIMERS.queue.length; }
    function flush() { return new Promise(function (r) { setImmediate(r); }); }

    function deferred() {
      var d = {};
      d.promise = new Promise(function (resolve, reject) { d.resolve = resolve; d.reject = reject; });
      return d;
    }

    function key(address) {
      return { toBase58: function () { return address; }, toString: function () { return address; } };
    }

    // Phantom's injected provider. `trusted` is the account a silent connect
    // returns; without it onlyIfTrusted rejects, as Phantom does for a site it
    // has not approved. `withoutOff` models an adapter with no way to remove a
    // listener.
    function fakePhantom(opts) {
      opts = opts || {};
      var handlers = {};
      var p = {
        isPhantom: true,
        name: opts.name || "Phantom",
        publicKey: opts.address ? key(opts.address) : null,
        connectCalls: [],
        pendingConnect: null,
        on: function (event, fn) { (handlers[event] = handlers[event] || []).push(fn); },
        emit: function (event, arg) {
          (handlers[event] || []).slice().forEach(function (fn) { fn(arg); });
        },
        listenerCount: function (event) { return (handlers[event] || []).length; },
        connect: function (o) {
          p.connectCalls.push(o || {});
          if (opts.deferConnect) {
            p.pendingConnect = deferred();
            return p.pendingConnect.promise;
          }
          if (o && o.onlyIfTrusted && !opts.trusted) {
            var err = new Error("User rejected the request.");
            err.code = 4001;
            return Promise.reject(err);
          }
          p.publicKey = key(opts.trusted);
          return Promise.resolve({ publicKey: p.publicKey });
        },
        // Wallet-side actions.
        userConnects: function (address) { p.publicKey = key(address); p.emit("connect", p.publicKey); },
        userSwitches: function (address) {
          p.publicKey = address ? key(address) : null;
          p.emit("accountChanged", p.publicKey);
        },
        userDisconnects: function () { p.publicKey = null; p.emit("disconnect"); },
        switchesSilently: function (address) { p.publicKey = address ? key(address) : null; }
      };
      if (!opts.withoutOff) {
        p.off = function (event, fn) {
          handlers[event] = (handlers[event] || []).filter(function (f) { return f !== fn; });
        };
      }
      return p;
    }

    function account(address) {
      return { address: address, publicKey: new Uint8Array(32), chains: ["solana:devnet"], features: [] };
    }

    // A raw Wallet Standard wallet.
    function fakeStandardWallet(opts) {
      opts = opts || {};
      var listeners = [];
      var w = {
        version: "1.0.0",
        name: opts.name || "Phantom",
        icon: "data:image/svg+xml;base64,",
        chains: ["solana:devnet"],
        accounts: opts.address ? [account(opts.address)] : [],
        connectCalls: [],
        pendingConnect: null,
        features: {
          "standard:connect": {
            version: "1.0.0",
            connect: function (input) {
              w.connectCalls.push(input || {});
              if (opts.deferConnect) {
                w.pendingConnect = deferred();
                return w.pendingConnect.promise;
              }
              if (input && input.silent && !opts.trusted) return Promise.resolve({ accounts: [] });
              w.accounts = [account(opts.trusted)];
              return Promise.resolve({ accounts: w.accounts });
            }
          },
          "standard:events": {
            version: "1.0.0",
            on: function (event, fn) {
              if (event !== "change") return function () {};
              listeners.push(fn);
              return function () { listeners = listeners.filter(function (f) { return f !== fn; }); };
            }
          }
        },
        listenerCount: function () { return listeners.length; },
        emitChange: function (props) { listeners.slice().forEach(function (fn) { fn(props); }); },
        userSwitches: function (address) {
          w.accounts = address ? [account(address)] : [];
          w.emitChange({ accounts: w.accounts });
        },
        switchesSilently: function (address) { w.accounts = address ? [account(address)] : []; }
      };
      return w;
    }

    // The identity-source contract from studio-engine docs/SESSION_DRIFT.md.
    function stubSession(identities) {
      var sources = {};
      var holds = [];
      var events = [];
      var session = {
        identities: identities || {},
        events: events,
        current: function () { return { identities: session.identities }; },
        registerIdentitySource: function (source) {
          if (!source || typeof source.start !== "function") throw new TypeError("a source needs start(report)");
          var name = String(source.name || "");
          if (!/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(name)) throw new TypeError("invalid source name");
          if (sources[name]) throw new Error("already registered");
          var entry = { observed: undefined, mismatch: null };
          sources[name] = entry;

          function boundValue() {
            var value = typeof source.bound === "function" ? source.bound(session.current()) : session.identities[name];
            return value == null || value === "" ? null : String(value);
          }

          function report(value) {
            if (sources[name] !== entry) return;
            entry.observed = value === undefined ? undefined : (value === null ? null : String(value));
            if (entry.observed === undefined) return;
            var bound = boundValue();
            var equal = bound === null ||
              (typeof source.equals === "function" ? !!source.equals(bound, entry.observed) : bound === entry.observed);
            if (equal) {
              if (!entry.mismatch) return;
              entry.mismatch = null;
              events.push({ type: "session:changed", reason: "resolved", source: name, expected: true, observed: entry.observed });
              return;
            }
            if (entry.mismatch && entry.mismatch.observed === entry.observed && entry.mismatch.bound === bound) return;
            entry.mismatch = { bound: bound, observed: entry.observed };
            var expected = holds.some(function (h) {
              return h.active && (h.scopes.indexOf(name) !== -1 || h.scopes.indexOf("*") !== -1);
            });
            events.push({ type: "session:changed", reason: "source", source: name, expected: expected, observed: entry.observed });
            if (!expected) events.push({ type: "session:mismatch", source: name, observed: entry.observed });
          }

          var stop = null;
          try { stop = source.start(report); } catch (e) { events.push({ type: "start_error", message: e.message }); }
          return {
            name: name,
            unregister: function () {
              if (sources[name] !== entry) return;
              delete sources[name];
              if (typeof stop === "function") stop();
            }
          };
        },
        expectChange: function (scope) {
          var hold = { scopes: [].concat(scope), active: true };
          holds.push(hold);
          return { scopes: hold.scopes, release: function () { hold.active = false; }, isActive: function () { return hold.active; } };
        },
        observed: function (name) { return sources[name] ? sources[name].observed : undefined; }
      };
      return session;
    }

    // Starts a source standalone and records what it reports and what it shows.
    function track(source) {
      var log = { reports: [], states: [] };
      source.subscribe(function (s) { log.states.push(s.status + (s.address ? ":" + s.address : "")); });
      log.stop = source.start(function (value) { log.reports.push(value === undefined ? "undefined" : value); });
      return log;
    }

    function view(source) {
      var s = source.current();
      return s.status + (s.address ? ":" + s.address : "");
    }
  JS

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  def setup
    # FAILS rather than skips, like every JS lane in this gem: a skipped lane is
    # lost coverage that reads as green, and bin/release-check rejects a skip.
    assert self.class.node?, "node is required to run this suite (install node)"
  end

  def run_js(script)
    program = <<~JS
      #{HARNESS}
      var A = #{A.to_json}, B = #{B.to_json}, C = #{C.to_json};
      #{File.read(SOURCE)}
      var WI = window.SolanaStudio.walletIdentity;
      Promise.resolve((async function () { #{script} })()).then(function (v) {
        process.stdout.write(JSON.stringify(v === undefined ? null : v));
      }, function (e) {
        process.stdout.write(JSON.stringify({ __error: String(e && e.stack || e) }));
      });
    JS

    Tempfile.create(["wallet_identity", ".js"]) do |f|
      f.write(program)
      f.flush
      # Separate streams: the source logs to console.error by design, and the
      # result is parsed from stdout alone.
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      result = JSON.parse(out)
      refute(result.is_a?(Hash) && result.key?("__error"), "script raised: #{result.is_a?(Hash) && result['__error']}")
      result
    end
  end

  # --- the harness itself -----------------------------------------------------

  def test_the_harness_keeps_stderr_out_of_the_parsed_result
    # The source logs to console.error on purpose (a throwing subscriber, a
    # throwing resolver). That must never reach the JSON this suite parses.
    result = run_js(<<~JS)
      console.error("noise on stderr");
      return "ok";
    JS
    assert_equal "ok", result
  end

  # --- the published API --------------------------------------------------------

  def test_the_asset_publishes_the_documented_api_once
    result = run_js(<<~JS)
      var first = WI;
      #{File.read(SOURCE)}
      return {
        statuses: WI.STATUSES,
        defaults: WI.DEFAULTS,
        create: typeof WI.create,
        register: typeof WI.register,
        sameObjectAfterSecondLoad: window.SolanaStudio.walletIdentity === first
      };
    JS

    assert_equal %w[unknown none disconnected connected], result["statuses"]
    assert_equal({ "name" => "wallet", "discoveryMs" => 3000, "discoveryIntervalMs" => 100,
                   "trustedConnect" => false, "disconnectIsMismatch" => false }, result["defaults"])
    assert_equal "function", result["create"]
    assert_equal "function", result["register"]
    assert result["sameObjectAfterSecondLoad"], "loading the asset twice must keep the first instance"
  end

  def test_a_source_carries_the_engine_contract_and_only_the_hooks_it_was_given
    result = run_js(<<~JS)
      var plain = WI.create();
      var bound = function () { return "x"; };
      var named = WI.create({ name: "phantom", bound: bound });
      return {
        name: plain.name, start: typeof plain.start, equals: typeof plain.equals,
        plainHasBound: "bound" in plain,
        namedName: named.name, namedBoundIsPassedThrough: named.bound === bound
      };
    JS

    assert_equal "wallet", result["name"]
    assert_equal "function", result["start"]
    assert_equal "function", result["equals"]
    refute result["plainHasBound"], "without a bound option the engine's default (identities[name]) must apply"
    assert_equal "phantom", result["namedName"]
    assert result["namedBoundIsPassedThrough"]
  end

  def test_only_a_different_connected_address_is_a_mismatch
    result = run_js(<<~JS)
      var loose = WI.create();
      var strict = WI.create({ disconnectIsMismatch: true });
      return {
        same: loose.equals(A, A), different: loose.equals(A, B), disconnected: loose.equals(A, null),
        strictDisconnected: strict.equals(A, null), strictDifferent: strict.equals(A, B)
      };
    JS

    assert_equal true, result["same"]
    assert_equal false, result["different"]
    assert_equal true, result["disconnected"], "a disconnect is not a switch to someone else"
    assert_equal false, result["strictDisconnected"]
    assert_equal false, result["strictDifferent"]
  end

  # --- no wallet, and not yet knowing -----------------------------------------------

  def test_no_provider_is_unknown_until_the_discovery_window_closes_then_none
    result = run_js(<<~JS)
      var source = WI.create({ getProvider: function () { return null; } });
      var log = track(source);
      var early = view(source);
      advance(2900);
      var justBefore = view(source);
      var reportsBefore = log.reports.slice();
      advance(100);
      return { early: early, justBefore: justBefore, reportsBefore: reportsBefore,
               after: view(source), reports: log.reports, pendingTimers: pendingTimers() };
    JS

    assert_equal "unknown", result["early"]
    assert_equal "unknown", result["justBefore"], "discovery still open must not read as no wallet"
    assert_empty result["reportsBefore"], "unknown reports nothing: the engine reads undefined as cannot tell"
    assert_equal "none", result["after"]
    assert_equal [nil], result["reports"]
    assert_equal 0, result["pendingTimers"], "a closed discovery window leaves no timer behind"
  end

  def test_discovery_ms_zero_reads_none_at_once
    result = run_js(<<~JS)
      var source = WI.create({ getProvider: function () { return null; }, discoveryMs: 0 });
      var log = track(source);
      return { now: view(source), reports: log.reports, pendingTimers: pendingTimers() };
    JS

    assert_equal "none", result["now"]
    assert_equal [nil], result["reports"]
    assert_equal 0, result["pendingTimers"]
  end

  def test_a_provider_injected_during_discovery_is_bound_without_passing_through_none
    result = run_js(<<~JS)
      var injected = null;
      var source = WI.create({ getProvider: function () { return injected; } });
      var log = track(source);
      advance(300);
      injected = fakePhantom({ address: A });
      advance(100);
      return { now: view(source), states: log.states, reports: log.reports, pendingTimers: pendingTimers() };
    JS

    assert_equal "connected:#{A}", result["now"]
    refute_includes result["states"], "none"
    assert_equal [A], result["reports"]
    assert_equal 0, result["pendingTimers"]
  end

  def test_a_provider_arriving_after_discovery_closed_binds_on_return_or_a_rescan_event
    result = run_js(<<~JS)
      var injected = null;
      var onFocus = WI.create({ getProvider: function () { return injected; } });
      var focusLog = track(onFocus);
      advance(3000);
      var closed = view(onFocus);
      injected = fakePhantom({ address: A });
      window.dispatch("focus");
      var afterFocus = view(onFocus);

      var late = null;
      var onRescan = WI.create({ getProvider: function () { return late; }, discoveryMs: 0,
                                 rescanOn: ["wallet-provider:registered"] });
      track(onRescan);
      late = fakeStandardWallet({ address: B });
      window.dispatch("wallet-provider:registered");
      return { closed: closed, afterFocus: afterFocus, focusReports: focusLog.reports, afterRescan: view(onRescan) };
    JS

    assert_equal "none", result["closed"]
    assert_equal "connected:#{A}", result["afterFocus"]
    assert_equal [nil, A], result["focusReports"]
    assert_equal "connected:#{B}", result["afterRescan"]
  end

  def test_a_throwing_resolver_reads_as_no_provider
    result = run_js(<<~JS)
      var source = WI.create({ getProvider: function () { throw new Error("registry not ready"); }, discoveryMs: 0 });
      track(source);
      return view(source);
    JS

    assert_equal "none", result
  end

  def test_an_unreadable_key_is_unknown_never_no_wallet
    result = run_js(<<~JS)
      var phantom = fakePhantom();
      phantom.publicKey = { opaque: true };
      var source = WI.create({ getProvider: function () { return phantom; } });
      var log = track(source);
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "unknown", result["now"]
    assert_empty result["reports"]
  end

  def test_the_default_resolver_reads_phantoms_injected_provider
    result = run_js(<<~JS)
      window.phantom = { solana: fakePhantom({ address: A }) };
      var source = WI.create();
      track(source);
      var viaPhantom = view(source);
      source.stop();
      delete window.phantom;
      window.solana = fakePhantom({ address: B });
      var fallback = WI.create();
      track(fallback);
      return { viaPhantom: viaPhantom, viaSolana: view(fallback) };
    JS

    assert_equal "connected:#{A}", result["viaPhantom"]
    assert_equal "connected:#{B}", result["viaSolana"]
  end

  # --- the legacy injected provider -------------------------------------------------

  def test_legacy_provider_without_an_account_reads_disconnected_and_is_never_probed
    result = run_js(<<~JS)
      var phantom = fakePhantom({ trusted: A });
      var source = WI.create({ getProvider: function () { return phantom; } });
      var log = track(source);
      window.dispatch("focus");
      await flush();
      return { now: view(source), reports: log.reports, connectCalls: phantom.connectCalls.length };
    JS

    assert_equal "disconnected", result["now"]
    assert_equal [nil], result["reports"]
    assert_equal 0, result["connectCalls"], "trustedConnect is off by default: a silent connect can pop the unlock prompt"
  end

  def test_legacy_connect_switch_lock_and_disconnect_each_report_the_live_address
    result = run_js(<<~JS)
      var phantom = fakePhantom();
      var source = WI.create({ getProvider: function () { return phantom; } });
      var log = track(source);
      phantom.userConnects(A);
      phantom.userSwitches(B);
      phantom.userSwitches(null);      // a lock, or a switch to an unapproved account
      phantom.userSwitches(A);
      phantom.userDisconnects();
      return { now: view(source), reports: log.reports, states: log.states };
    JS

    assert_equal "disconnected", result["now"]
    assert_equal [nil, A, B, nil, A, nil], result["reports"]
    assert_equal ["disconnected", "connected:#{A}", "connected:#{B}", "disconnected", "connected:#{A}", "disconnected"],
                 result["states"]
  end

  def test_legacy_provider_name_is_carried_for_the_page
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A, name: "Phantom" });
      var source = WI.create({ getProvider: function () { return phantom; } });
      track(source);
      return source.current();
    JS

    assert_equal({ "status" => "connected", "address" => A, "providerName" => "Phantom" }, result)
  end

  def test_legacy_listeners_bind_once_however_often_the_page_reconciles
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var source = WI.create({ getProvider: function () { return phantom; } });
      var log = track(source);
      for (var i = 0; i < 5; i++) window.dispatch("focus");
      window.dispatch("pageshow");
      document.dispatch("visibilitychange");
      source.reconcile();
      return {
        accountChanged: phantom.listenerCount("accountChanged"),
        connect: phantom.listenerCount("connect"),
        disconnect: phantom.listenerCount("disconnect"),
        reports: log.reports
      };
    JS

    assert_equal 1, result["accountChanged"]
    assert_equal 1, result["connect"]
    assert_equal 1, result["disconnect"]
    assert_equal [A], result["reports"], "re-reading the same wallet reports nothing new"
  end

  def test_stop_removes_legacy_listeners_and_page_listeners
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var source = WI.create({ getProvider: function () { return phantom; }, rescanOn: ["wallet-provider:registered"] });
      var log = track(source);
      log.stop();
      phantom.userSwitches(B);
      return {
        accountChanged: phantom.listenerCount("accountChanged"),
        focus: window.listenerCount("focus"),
        pageshow: window.listenerCount("pageshow"),
        rescan: window.listenerCount("wallet-provider:registered"),
        visibility: document.listenerCount("visibilitychange"),
        running: source.isRunning(),
        reports: log.reports
      };
    JS

    assert_equal 0, result["accountChanged"]
    assert_equal 0, result["focus"]
    assert_equal 0, result["pageshow"]
    assert_equal 0, result["rescan"]
    assert_equal 0, result["visibility"]
    assert_equal false, result["running"]
    assert_equal [A], result["reports"], "a stopped source reports nothing"
  end

  def test_starting_twice_throws_and_a_stopped_source_restarts_cleanly
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var source = WI.create({ getProvider: function () { return phantom; } });
      var stop = source.start(function () {});
      var threw = null;
      try { source.start(function () {}); } catch (e) { threw = e.message; }
      stop();
      var reports = [];
      source.start(function (v) { reports.push(v); });
      phantom.userSwitches(B);
      return { threw: threw, reports: reports, listeners: phantom.listenerCount("accountChanged") };
    JS

    assert_match(/already started/, result["threw"])
    assert_equal [A, B], result["reports"], "a restart reports the live wallet to the new report function"
    assert_equal 1, result["listeners"]
  end

  # --- the Wallet Standard wallet -------------------------------------------------------

  def test_wallet_standard_connect_switch_and_disconnect_each_report_the_live_address
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet();
      var source = WI.create({ getProvider: function () { return wallet; } });
      var log = track(source);
      wallet.userSwitches(A);
      wallet.userSwitches(B);
      wallet.userSwitches(null);        // an empty accounts array IS the disconnect
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "disconnected", result["now"]
    assert_equal [nil, A, B, nil], result["reports"]
  end

  def test_wallet_standard_reads_the_wallets_live_accounts_not_the_events_copy
    # The wallet-switch-rehydrates-session lesson, at this layer: the wallet's
    # own `accounts` is the truth, and a value carried from somewhere else is
    # only a copy of it.
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet({ address: A });
      var source = WI.create({ getProvider: function () { return wallet; } });
      var log = track(source);
      wallet.switchesSilently(B);
      wallet.emitChange({ accounts: [account(A)] });
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "connected:#{B}", result["now"]
    assert_equal [A, B], result["reports"]
  end

  def test_a_wallet_standard_change_without_accounts_says_nothing_about_identity
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet({ address: A });
      var source = WI.create({ getProvider: function () { return wallet; } });
      var log = track(source);
      wallet.emitChange({ chains: ["solana:mainnet"] });
      wallet.emitChange(undefined);
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "connected:#{A}", result["now"]
    assert_equal [A], result["reports"]
  end

  def test_wallet_standard_listener_binds_once_and_unsubscribes_on_stop
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet({ address: A });
      var source = WI.create({ getProvider: function () { return wallet; } });
      var log = track(source);
      for (var i = 0; i < 4; i++) window.dispatch("focus");
      var whileRunning = wallet.listenerCount();
      log.stop();
      wallet.userSwitches(B);
      return { whileRunning: whileRunning, afterStop: wallet.listenerCount(), reports: log.reports };
    JS

    assert_equal 1, result["whileRunning"]
    assert_equal 0, result["afterStop"]
    assert_equal [A], result["reports"]
  end

  # --- a switch the wallet never announced ----------------------------------------------

  def test_a_switch_made_while_the_tab_was_hidden_is_caught_when_it_becomes_visible
    result = run_js(<<~JS)
      var out = {};
      [["legacy", fakePhantom({ address: A })], ["standard", fakeStandardWallet({ address: A })]].forEach(function (pair) {
        var provider = pair[1];
        var source = WI.create({ getProvider: function () { return provider; } });
        var log = track(source);
        document.visibilityState = "hidden";
        document.dispatch("visibilitychange");
        provider.switchesSilently(B);
        var whileHidden = view(source);
        document.dispatch("visibilitychange");           // still hidden: nothing to re-read yet
        var stillHidden = view(source);
        document.visibilityState = "visible";
        document.dispatch("visibilitychange");
        out[pair[0]] = { whileHidden: whileHidden, stillHidden: stillHidden, visible: view(source), reports: log.reports };
        log.stop();
      });
      return out;
    JS

    %w[legacy standard].each do |shape|
      assert_equal "connected:#{A}", result[shape]["whileHidden"], shape
      assert_equal "connected:#{A}", result[shape]["stillHidden"], shape
      assert_equal "connected:#{B}", result[shape]["visible"], "#{shape}: returning to the tab must re-read the wallet"
      assert_equal [A, B], result[shape]["reports"], shape
    end
  end

  def test_an_unannounced_switch_is_caught_on_focus_and_on_pageshow
    result = run_js(<<~JS)
      var out = {};
      [["legacy", fakePhantom({ address: A })], ["standard", fakeStandardWallet({ address: A })]].forEach(function (pair) {
        var provider = pair[1];
        var source = WI.create({ getProvider: function () { return provider; } });
        var log = track(source);
        provider.switchesSilently(B);
        window.dispatch("focus");
        var afterFocus = view(source);
        provider.switchesSilently(C);
        window.dispatch("pageshow");                    // a bfcache restore
        out[pair[0]] = { afterFocus: afterFocus, afterPageshow: view(source), reports: log.reports };
        log.stop();
      });
      return out;
    JS

    %w[legacy standard].each do |shape|
      assert_equal "connected:#{B}", result[shape]["afterFocus"], shape
      assert_equal "connected:#{C}", result[shape]["afterPageshow"], shape
      assert_equal [A, B, C], result[shape]["reports"], shape
    end
  end

  def test_a_disconnect_while_hidden_reads_disconnected_on_return
    result = run_js(<<~JS)
      var out = {};
      [["legacy", fakePhantom({ address: A })], ["standard", fakeStandardWallet({ address: A })]].forEach(function (pair) {
        var provider = pair[1];
        var source = WI.create({ getProvider: function () { return provider; } });
        var log = track(source);
        document.visibilityState = "hidden";
        provider.switchesSilently(null);
        document.visibilityState = "visible";
        document.dispatch("visibilitychange");
        out[pair[0]] = { now: view(source), reports: log.reports };
        log.stop();
      });
      return out;
    JS

    %w[legacy standard].each do |shape|
      assert_equal "disconnected", result[shape]["now"], shape
      assert_equal [A, nil], result[shape]["reports"], shape
    end
  end

  # --- a provider replaced by a later one ---------------------------------------------------

  def test_a_superseded_provider_is_ignored_and_detached
    result = run_js(<<~JS)
      var legacy = fakePhantom({ address: A });
      var standard = null;
      var source = WI.create({ getProvider: function () { return standard || legacy; } });
      var log = track(source);
      standard = fakeStandardWallet({ address: B });
      window.dispatch("focus");
      legacy.userSwitches(C);                           // the old interface keeps talking
      return { now: view(source), reports: log.reports,
               legacyListeners: legacy.listenerCount("accountChanged"), standardListeners: standard.listenerCount() };
    JS

    assert_equal "connected:#{B}", result["now"]
    assert_equal [A, B], result["reports"], "an event from the superseded provider must not be reported"
    assert_equal 0, result["legacyListeners"]
    assert_equal 1, result["standardListeners"]
  end

  def test_a_provider_that_cannot_remove_listeners_is_not_bound_twice_when_it_returns
    result = run_js(<<~JS)
      var first = fakePhantom({ address: A, withoutOff: true });
      var second = fakePhantom({ address: B });
      var pick = first;
      var source = WI.create({ getProvider: function () { return pick; } });
      var log = track(source);
      pick = second; window.dispatch("focus");
      first.userSwitches(C);                            // inert while superseded
      var whileSuperseded = view(source);
      pick = first; window.dispatch("focus");
      pick = second; window.dispatch("focus");
      pick = first; window.dispatch("focus");
      first.userSwitches(A);
      return { whileSuperseded: whileSuperseded, now: view(source),
               firstListeners: first.listenerCount("accountChanged"), reports: log.reports };
    JS

    assert_equal "connected:#{B}", result["whileSuperseded"]
    assert_equal 1, result["firstListeners"], "a listener that cannot be removed must not be stacked"
    assert_equal "connected:#{A}", result["now"], "the returning provider's events are heard again"
    assert_equal [A, B, C, B, C, A], result["reports"]
  end

  # --- a silent connect for a trusted site ----------------------------------------------------

  def test_trusted_connect_stays_unknown_until_the_silent_connect_settles
    result = run_js(<<~JS)
      var phantom = fakePhantom({ deferConnect: true });
      var source = WI.create({ getProvider: function () { return phantom; }, trustedConnect: true });
      var log = track(source);
      var pending = view(source);
      var reportsPending = log.reports.slice();
      phantom.publicKey = key(A);
      phantom.pendingConnect.resolve({ publicKey: key(A) });
      await flush();
      return { pending: pending, reportsPending: reportsPending, settled: view(source),
               reports: log.reports, call: phantom.connectCalls[0] };
    JS

    assert_equal "unknown", result["pending"], "a probe in flight must not read as disconnected"
    assert_empty result["reportsPending"]
    assert_equal "connected:#{A}", result["settled"]
    assert_equal [A], result["reports"]
    assert_equal({ "onlyIfTrusted" => true }, result["call"])
  end

  def test_trusted_connect_rejected_reads_disconnected_on_both_shapes
    result = run_js(<<~JS)
      var legacy = fakePhantom();
      var standard = fakeStandardWallet();
      var a = WI.create({ getProvider: function () { return legacy; }, trustedConnect: true });
      var b = WI.create({ getProvider: function () { return standard; }, trustedConnect: true });
      var logA = track(a), logB = track(b);
      await flush();
      return { legacy: view(a), standard: view(b), legacyReports: logA.reports, standardReports: logB.reports,
               legacyCall: legacy.connectCalls[0], standardCall: standard.connectCalls[0] };
    JS

    assert_equal "disconnected", result["legacy"]
    assert_equal "disconnected", result["standard"]
    assert_equal [nil], result["legacyReports"]
    assert_equal [nil], result["standardReports"]
    assert_equal({ "onlyIfTrusted" => true }, result["legacyCall"])
    assert_equal({ "silent" => true }, result["standardCall"])
  end

  def test_trusted_connect_resolves_on_wallet_standard_by_reading_accounts_live
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet({ trusted: A });
      var source = WI.create({ getProvider: function () { return wallet; }, trustedConnect: true });
      var log = track(source);
      await flush();
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "connected:#{A}", result["now"]
    assert_equal [A], result["reports"]
  end

  def test_a_wallet_event_during_the_silent_connect_wins_over_its_answer
    result = run_js(<<~JS)
      var phantom = fakePhantom({ deferConnect: true });
      var source = WI.create({ getProvider: function () { return phantom; }, trustedConnect: true });
      var log = track(source);
      phantom.userSwitches(B);
      phantom.pendingConnect.resolve({ publicKey: key(A) });
      await flush();
      return { now: view(source), reports: log.reports };
    JS

    assert_equal "connected:#{B}", result["now"]
    assert_equal [B], result["reports"]
  end

  def test_a_reconcile_probe_keeps_the_settled_status_until_it_answers
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A, deferConnect: true });
      var source = WI.create({ getProvider: function () { return phantom; }, trustedConnect: true });
      var log = track(source);
      phantom.switchesSilently(null);
      window.dispatch("focus");
      var whileProbing = view(source);
      window.dispatch("focus");                         // a second return does not start a second probe
      var calls = phantom.connectCalls.length;
      phantom.pendingConnect.reject(new Error("User rejected the request."));
      await flush();
      return { whileProbing: whileProbing, calls: calls, now: view(source), states: log.states, reports: log.reports };
    JS

    assert_equal "connected:#{A}", result["whileProbing"], "no flash back to unknown or disconnected mid-probe"
    assert_equal 1, result["calls"]
    assert_equal "disconnected", result["now"]
    refute_includes result["states"], "unknown"
    assert_equal [A, nil], result["reports"]
  end

  # --- subscribers ---------------------------------------------------------------------

  def test_a_throwing_subscriber_does_not_starve_the_next_and_unsubscribe_works
    result = run_js(<<~JS)
      var phantom = fakePhantom();
      var source = WI.create({ getProvider: function () { return phantom; } });
      var seen = [], late = [];
      source.subscribe(function () { throw new Error("boom"); });
      source.subscribe(function (next, previous) { seen.push(previous.status + ">" + next.status); });
      var off = source.subscribe(function (next) { late.push(next.status); });
      source.start();
      off();
      phantom.userConnects(A);
      return { seen: seen, late: late };
    JS

    assert_equal ["unknown>disconnected", "disconnected>connected"], result["seen"]
    assert_equal ["disconnected"], result["late"]
  end

  # --- through the session store (the StudioSession contract) ------------------------------

  def test_an_undeclared_switch_is_a_mismatch_and_switching_back_resolves_it
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var session = stubSession({ wallet: A });
      var wired = WI.register({ session: session, getProvider: function () { return phantom; } });
      phantom.userSwitches(B);
      phantom.userSwitches(A);
      return { events: session.events, observed: session.observed("wallet"), named: wired.registration.name };
    JS

    assert_equal "wallet", result["named"]
    assert_equal [
      { "type" => "session:changed", "reason" => "source", "source" => "wallet", "expected" => false, "observed" => B },
      { "type" => "session:mismatch", "source" => "wallet", "observed" => B },
      { "type" => "session:changed", "reason" => "resolved", "source" => "wallet", "expected" => true, "observed" => A }
    ], result["events"]
    assert_equal A, result["observed"]
  end

  def test_a_declared_switch_under_a_hold_is_expected_and_raises_no_mismatch
    result = run_js(<<~JS)
      var wallet = fakeStandardWallet({ address: A });
      var session = stubSession({ wallet: A });
      WI.register({ session: session, getProvider: function () { return wallet; } });
      var hold = session.expectChange("wallet");
      wallet.userSwitches(B);
      hold.release();
      wallet.userSwitches(C);
      return session.events;
    JS

    assert_equal [
      { "type" => "session:changed", "reason" => "source", "source" => "wallet", "expected" => true, "observed" => B },
      { "type" => "session:changed", "reason" => "source", "source" => "wallet", "expected" => false, "observed" => C },
      { "type" => "session:mismatch", "source" => "wallet", "observed" => C }
    ], result
  end

  def test_a_disconnect_is_not_a_mismatch_unless_the_host_opts_in
    result = run_js(<<~JS)
      var loose = fakePhantom({ address: A });
      var looseSession = stubSession({ wallet: A });
      var looseWired = WI.register({ session: looseSession, getProvider: function () { return loose; } });
      loose.userDisconnects();

      var strict = fakePhantom({ address: A });
      var strictSession = stubSession({ wallet: A });
      WI.register({ session: strictSession, getProvider: function () { return strict; }, disconnectIsMismatch: true });
      strict.userDisconnects();
      return { looseEvents: looseSession.events, looseStatus: view(looseWired.source),
               looseObserved: looseSession.observed("wallet"), strictTypes: strictSession.events.map(function (e) { return e.type; }) };
    JS

    assert_empty result["looseEvents"]
    assert_equal "disconnected", result["looseStatus"], "the page still sees the disconnect"
    assert_nil result["looseObserved"]
    assert_equal ["session:changed", "session:mismatch"], result["strictTypes"]
  end

  def test_a_pre_auth_page_binds_no_wallet_and_never_mismatches
    result = run_js(<<~JS)
      var phantom = fakePhantom();
      var session = stubSession({});
      var wired = WI.register({ session: session, getProvider: function () { return phantom; } });
      var before = view(wired.source);
      phantom.userConnects(A);
      phantom.userSwitches(B);
      return { before: before, after: view(wired.source), observed: session.observed("wallet"), events: session.events };
    JS

    assert_equal "disconnected", result["before"]
    assert_equal "connected:#{B}", result["after"]
    assert_equal B, result["observed"], "an unbound session still records what the wallet shows"
    assert_empty result["events"]
  end

  def test_unknown_reports_nothing_to_the_session_so_a_bound_page_is_not_warned_early
    result = run_js(<<~JS)
      var injected = null;
      var session = stubSession({ wallet: A });
      var wired = WI.register({ session: session, getProvider: function () { return injected; } });
      var whileUnknown = session.observed("wallet");
      advance(3000);
      return { whileUnknown: whileUnknown === undefined ? "undefined" : whileUnknown,
               afterDiscovery: session.observed("wallet"), status: view(wired.source), events: session.events };
    JS

    assert_equal "undefined", result["whileUnknown"]
    assert_nil result["afterDiscovery"]
    assert_equal "none", result["status"]
    assert_empty result["events"]
  end

  def test_register_uses_window_studio_session_by_default_and_unregister_stops_the_source
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      window.StudioSession = stubSession({ wallet: A });
      var wired = WI.register({ getProvider: function () { return phantom; } });
      var observed = window.StudioSession.observed("wallet");
      wired.registration.unregister();
      phantom.userSwitches(B);
      return { observed: observed, running: wired.source.isRunning(),
               listeners: phantom.listenerCount("accountChanged"), events: window.StudioSession.events };
    JS

    assert_equal A, result["observed"]
    assert_equal false, result["running"]
    assert_equal 0, result["listeners"]
    assert_empty result["events"]
  end

  def test_register_without_a_session_store_still_runs_the_source
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var wired = WI.register({ getProvider: function () { return phantom; } });
      phantom.userSwitches(B);
      return { registration: wired.registration, running: wired.source.isRunning(), now: view(wired.source) };
    JS

    assert_nil result["registration"]
    assert_equal true, result["running"]
    assert_equal "connected:#{B}", result["now"]
  end

  def test_a_custom_name_and_bound_hook_drive_the_comparison
    result = run_js(<<~JS)
      var phantom = fakePhantom({ address: A });
      var session = stubSession({ wallet: A });
      WI.register({ session: session, name: "signer", getProvider: function () { return phantom; },
                    bound: function () { return B; } });
      return { observed: session.observed("signer"), events: session.events };
    JS

    assert_equal A, result["observed"]
    assert_equal [
      { "type" => "session:changed", "reason" => "source", "source" => "signer", "expected" => false, "observed" => A },
      { "type" => "session:mismatch", "source" => "signer", "observed" => A }
    ], result["events"]
  end
end
