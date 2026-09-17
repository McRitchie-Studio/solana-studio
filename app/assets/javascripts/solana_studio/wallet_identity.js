// SolanaStudio.walletIdentity — the browser wallet as a session identity source.
//
// WHAT IT IS. studio-engine's session-drift primitive (window.StudioSession,
// studio/session.js) compares the identities a page was rendered for against the
// identities the browser observes now. The engine is web2 by rule and knows
// nothing about wallets; it takes an IDENTITY SOURCE instead:
//
//   StudioSession.registerIdentitySource({ name, start(report), bound?, equals? })
//
// This file is that source for a Solana wallet. The identity it observes is the
// connected wallet address. A host registers it once per window (a Turbo visit
// keeps the store and the registration; the same name twice throws):
//
//   var wallet = SolanaStudio.walletIdentity.register({ getProvider: ..., trustedConnect: ... });
//   wallet.source.current();   // { status, address, providerName }
//
// WHAT IT REPORTS, in the engine's vocabulary:
//
//   status        report()     meaning
//   unknown       undefined    cannot tell yet: discovery or a silent connect is pending
//   none          null         no wallet provider on this page after discovery
//   disconnected  null         a provider is present and holds no account for this site
//   connected     "<address>"  this wallet is connected
//
// "Not yet known" and "no wallet" never collapse. A navbar that renders from
// `unknown` as if it were `none` tells someone with a wallet that they have none.
// The engine sees only the report column; the four statuses are for the page.
//
// WHAT A MISMATCH IS. Only a DIFFERENT connected address. A disconnect, a locked
// extension, or a page with no wallet at all is not a switch to someone else, so
// `equals` treats an observed null as agreeing with any bound address unless the
// host passes `disconnectIsMismatch: true`. The page still sees the disconnect
// through `current()` and `subscribe()`.
//
// THE LESSONS THIS CARRIES, each one paid for in turf-monster:
//
//   · READ THE WALLET LIVE. A Wallet Standard wallet's `accounts` is its own
//     current view. An adapter that answered from a value cached at connect time
//     reported the PREVIOUS account forever after a switch the wallet never
//     announced (turf-monster wallet-switch-rehydrates-session). Nothing here
//     caches an address as the truth: every read goes back to the wallet.
//
//   · EVENTS ARE BEST-EFFORT. A switch made while the tab was hidden, or while a
//     wallet side panel held focus, can arrive late or not at all. Returning to
//     the page (focus, visibilitychange to visible, pageshow) re-resolves the
//     provider and re-reads it.
//
//   · IDENTITY BY CLOSURE. A provider replaced by a later one (a Wallet Standard
//     registration superseding the injected object) must stay ignored. That is
//     decided by comparing the binding held in this closure, never a field read
//     back off a reactive store, which returns a proxy that equals nothing.
//
//   · BIND ONCE. Listeners attach once per provider object, however many times
//     discovery and focus re-resolve it.
//
//   · A SILENT CONNECT IS NOT FREE. `connect({ onlyIfTrusted: true })` can pop
//     Phantom's unlock prompt on a locked extension, so it is OFF by default. A
//     host turns it on only where a wallet session is already expected.
//
// It never signs, never sends, never writes storage, and never opens a modal.
// Written as ES5 with Promises, like the other assets in this engine, so every
// host's asset pipeline accepts it untouched.
(function (W) {
  "use strict";

  W.SolanaStudio = W.SolanaStudio || {};
  if (W.SolanaStudio.walletIdentity && W.SolanaStudio.walletIdentity.loaded) return;

  var STATUSES = ["unknown", "none", "disconnected", "connected"];

  var DEFAULTS = {
    name: "wallet",
    discoveryMs: 3000,
    discoveryIntervalMs: 100,
    trustedConnect: false,
    disconnectIsMismatch: false
  };

  function logError(error) {
    if (typeof console !== "undefined" && console.error) console.error("[SolanaStudio.walletIdentity]", error);
  }

  // The injected provider a page with no registry of its own would watch.
  function defaultProvider() {
    var phantom = W.phantom && W.phantom.solana;
    return phantom || W.solana || null;
  }

  // A raw Wallet Standard wallet carries `features` and its own `accounts`.
  // Everything else is treated as an injected provider: Phantom's legacy
  // `window.phantom.solana`, or a host adapter normalized to that shape.
  function isWalletStandard(provider) {
    return !!(provider && provider.features && typeof provider.features === "object" &&
      "accounts" in provider);
  }

  // A key, a Wallet Standard account, or a base58 string → an address.
  // null means "no account"; undefined means "an account I cannot read", which
  // is "cannot tell", never "no wallet".
  function addressOf(key) {
    if (key == null) return null;
    if (typeof key === "string") return key === "" ? null : key;
    if (typeof key.address === "string") return key.address === "" ? null : key.address;
    if (typeof key.toBase58 === "function") {
      var text = key.toBase58();
      return text ? String(text) : undefined;
    }
    return undefined;
  }

  // THE LIVE READ. Always the wallet's own current answer.
  function liveAddress(provider) {
    try {
      if (isWalletStandard(provider)) {
        var accounts = provider.accounts;
        if (!accounts) return undefined;
        return accounts.length ? addressOf(accounts[0]) : null;
      }
      return addressOf(provider.publicKey);
    } catch (e) {
      logError(e);
      return undefined;
    }
  }

  function providerNameOf(provider) {
    return provider && typeof provider.name === "string" && provider.name ? provider.name : null;
  }

  function create(options) {
    options = options || {};
    var name = options.name == null ? DEFAULTS.name : String(options.name);
    var getProvider = typeof options.getProvider === "function" ? options.getProvider : defaultProvider;
    var trustedConnect = options.trustedConnect === undefined ? DEFAULTS.trustedConnect : !!options.trustedConnect;
    var disconnectIsMismatch = !!options.disconnectIsMismatch;
    var discoveryMs = typeof options.discoveryMs === "number" ? options.discoveryMs : DEFAULTS.discoveryMs;
    var intervalMs = typeof options.discoveryIntervalMs === "number" && options.discoveryIntervalMs > 0
      ? options.discoveryIntervalMs : DEFAULTS.discoveryIntervalMs;
    var rescanOn = [].concat(options.rescanOn || []);

    var running = false;
    var reportFn = null;
    var subscribers = [];

    // The binding for the provider currently watched. One per provider OBJECT,
    // kept for the life of the source so a provider re-resolved later is not
    // bound a second time.
    var current = null;
    var bindings = [];

    var discoveryTimer = null;
    var discoveryTicks = 0;
    var discoveryDone = false;

    var state = { status: "unknown", address: null, providerName: null };
    var reported;         // the last value handed to report(); starts undefined
    var probing = null;   // the binding whose silent connect is in flight

    function snapshot() {
      return { status: state.status, address: state.address, providerName: state.providerName };
    }

    function reportValue(next) {
      if (next.status === "connected") return next.address;
      if (next.status === "unknown") return undefined;
      return null;
    }

    function setState(next) {
      if (next.status === state.status && next.address === state.address &&
          next.providerName === state.providerName) return;
      var previous = snapshot();
      state = { status: next.status, address: next.address, providerName: next.providerName };

      var value = reportValue(state);
      if (value !== reported) {
        reported = value;
        if (reportFn) {
          try { reportFn(value); } catch (e) { logError(e); }
        }
      }

      var list = subscribers.slice();
      for (var i = 0; i < list.length; i++) {
        try { list[i](snapshot(), previous); } catch (e) { logError(e); }
      }
    }

    // Folds one observation of `binding` into the state. `address` is null, a
    // string, or undefined (cannot tell).
    function observe(binding, address) {
      if (!running || binding !== current) return;
      if (address === undefined) {
        // An unreadable answer changes nothing once a status has settled; before
        // that, the page honestly cannot tell yet.
        if (!binding.settled) setState({ status: "unknown", address: null, providerName: providerNameOf(binding.provider) });
        return;
      }
      binding.settled = true;
      setState({
        status: address === null ? "disconnected" : "connected",
        address: address,
        providerName: providerNameOf(binding.provider)
      });
    }

    function findBinding(provider) {
      for (var i = 0; i < bindings.length; i++) {
        if (bindings[i].provider === provider) return bindings[i];
      }
      return null;
    }

    function attach(binding) {
      var provider = binding.provider;
      binding.detach = null;
      try {
        if (isWalletStandard(provider)) {
          var events = provider.features["standard:events"];
          if (!events || typeof events.on !== "function") return;
          var off = events.on("change", function (props) {
            // Only a change that carries accounts says anything about identity.
            if (!props || !("accounts" in props)) return;
            binding.eventSeq += 1;
            // The wallet's live view, not the event's copy of it.
            var live = liveAddress(provider);
            observe(binding, live === undefined ? addressOf((props.accounts || [])[0]) : live);
          });
          binding.detach = typeof off === "function" ? off : null;
          return;
        }

        if (typeof provider.on !== "function") return;
        var onAccountChanged = function (key) {
          binding.eventSeq += 1;
          // A null here is a real observation: Phantom sends it on a lock, a
          // disconnect, and a switch to an account this site was never approved for.
          if (key == null) { observe(binding, null); return; }
          var address = addressOf(key);
          observe(binding, address === undefined ? liveAddress(provider) : address);
        };
        var onConnect = function (key) {
          binding.eventSeq += 1;
          var address = key == null ? undefined : addressOf(key);
          observe(binding, address === undefined ? liveAddress(provider) : address);
        };
        var onDisconnect = function () {
          binding.eventSeq += 1;
          observe(binding, null);
        };
        provider.on("accountChanged", onAccountChanged);
        provider.on("connect", onConnect);
        provider.on("disconnect", onDisconnect);
        var remove = typeof provider.off === "function" ? "off"
          : (typeof provider.removeListener === "function" ? "removeListener" : null);
        if (remove) {
          binding.detach = function () {
            provider[remove]("accountChanged", onAccountChanged);
            provider[remove]("connect", onConnect);
            provider[remove]("disconnect", onDisconnect);
          };
        }
      } catch (e) {
        logError(e);
      }
    }

    function detach(binding) {
      if (!binding.attached) return;
      if (binding.detach) {
        try { binding.detach(); } catch (e) { logError(e); }
        binding.attached = false;
        binding.detach = null;
      }
      // A provider with no way to remove a listener keeps it; the closure check
      // in observe() is what makes that listener inert, and `attached` staying
      // true is what stops a second copy from ever being added.
    }

    function bind(provider) {
      var binding = findBinding(provider);
      if (!binding) {
        binding = { provider: provider, attached: false, detach: null, settled: false, eventSeq: 0 };
        bindings.push(binding);
      }
      if (current && current !== binding) detach(current);
      current = binding;
      binding.settled = false;
      if (!binding.attached) {
        binding.attached = true;
        attach(binding);
      }
      return binding;
    }

    // Asks a trusted wallet for its account without prompting. The status stays
    // `unknown` until it settles on a first bind; on a later reconcile the last
    // settled status stands meanwhile, so the page never flashes back to unknown.
    // Returns true while a probe is in flight for this binding.
    function probe(binding) {
      if (probing === binding) return true;
      var provider = binding.provider;
      var attempt;
      try {
        if (isWalletStandard(provider)) {
          var connect = provider.features["standard:connect"];
          if (!connect || typeof connect.connect !== "function") return false;
          attempt = connect.connect({ silent: true });
        } else {
          if (typeof provider.connect !== "function") return false;
          attempt = provider.connect({ onlyIfTrusted: true });
        }
      } catch (e) {
        attempt = Promise.reject(e);
      }
      if (!attempt || typeof attempt.then !== "function") return false;

      probing = binding;
      var seq = binding.eventSeq;
      if (!binding.settled) setState({ status: "unknown", address: null, providerName: providerNameOf(provider) });

      attempt.then(function (result) {
        if (probing === binding) probing = null;
        // A wallet event since the probe began is fresher than its answer.
        if (binding.eventSeq !== seq) return;
        var live = liveAddress(provider);
        if (live == null && result) {
          var carried = result.publicKey !== undefined ? addressOf(result.publicKey)
            : addressOf((result.accounts || [])[0]);
          if (carried) live = carried;
        }
        observe(binding, live);
      }, function () {
        if (probing === binding) probing = null;
        if (binding.eventSeq !== seq) return;
        // Not trusted, locked, or dismissed: nothing is connected for this site.
        var live = liveAddress(provider);
        observe(binding, live === undefined ? null : live);
      });
      return true;
    }

    function resolveProvider() {
      try {
        return getProvider() || null;
      } catch (e) {
        logError(e);
        return null;
      }
    }

    function stopDiscovery() {
      if (discoveryTimer !== null) {
        W.clearTimeout(discoveryTimer);
        discoveryTimer = null;
      }
    }

    // Polls for a provider injected after this script ran. The window closes
    // after discoveryMs, and only then does "no provider yet" become `none`.
    function scheduleDiscovery() {
      if (discoveryTimer !== null || discoveryDone) return;
      discoveryTimer = W.setTimeout(function () {
        discoveryTimer = null;
        if (!running || discoveryDone) return;
        discoveryTicks += 1;
        var provider = resolveProvider();
        if (provider) {
          reconcileWith(provider);
          return;
        }
        if (discoveryTicks * intervalMs >= discoveryMs) {
          discoveryDone = true;
          setState({ status: "none", address: null, providerName: null });
          return;
        }
        scheduleDiscovery();
      }, intervalMs);
    }

    // Re-resolves the provider and re-reads it live. Returns the binding watched
    // afterwards, or null when there is still no provider.
    function reconcile() {
      if (!running) return null;
      return reconcileWith(resolveProvider());
    }

    function reconcileWith(provider) {
      if (!provider) {
        // A provider already bound does not vanish from a live page; a resolver
        // that briefly answers null keeps the binding it has.
        if (current) {
          readAndProbe(current);
          return current;
        }
        // discoveryMs <= 0 is a host saying it will not wait for a late injection.
        if (discoveryDone || discoveryMs <= 0) {
          discoveryDone = true;
          setState({ status: "none", address: null, providerName: null });
        } else {
          scheduleDiscovery();
        }
        return null;
      }
      stopDiscovery();
      discoveryDone = true;
      var binding = current && current.provider === provider ? current : bind(provider);
      readAndProbe(binding);
      return binding;
    }

    // A wallet holding no account may still be trusted by this site. With
    // trustedConnect on, that is asked before `disconnected` is believed; the
    // status meanwhile is whatever last settled, or `unknown` on a first bind.
    function readAndProbe(binding) {
      var live = liveAddress(binding.provider);
      if (live === null && trustedConnect && probe(binding)) return;
      observe(binding, live);
    }

    function onReturn() {
      if (typeof document !== "undefined" && document.visibilityState && document.visibilityState !== "visible") return;
      reconcile();
    }

    function onPageShow() { reconcile(); }
    function onRescan() { reconcile(); }

    function start(report) {
      if (running) throw new Error("SolanaStudio.walletIdentity: source " + JSON.stringify(name) + " is already started");
      running = true;
      reportFn = typeof report === "function" ? report : null;
      reported = undefined;
      discoveryTicks = 0;
      discoveryDone = false;
      current = null;
      setState({ status: "unknown", address: null, providerName: null });

      if (typeof W.addEventListener === "function") {
        W.addEventListener("focus", onReturn);
        W.addEventListener("pageshow", onPageShow);
        for (var i = 0; i < rescanOn.length; i++) W.addEventListener(rescanOn[i], onRescan);
      }
      if (typeof document !== "undefined" && typeof document.addEventListener === "function") {
        document.addEventListener("visibilitychange", onReturn);
      }

      reconcile();
      return stop;
    }

    function stop() {
      if (!running) return;
      running = false;
      reportFn = null;
      probing = null;
      stopDiscovery();
      if (typeof W.removeEventListener === "function") {
        W.removeEventListener("focus", onReturn);
        W.removeEventListener("pageshow", onPageShow);
        for (var i = 0; i < rescanOn.length; i++) W.removeEventListener(rescanOn[i], onRescan);
      }
      if (typeof document !== "undefined" && typeof document.removeEventListener === "function") {
        document.removeEventListener("visibilitychange", onReturn);
      }
      for (var j = 0; j < bindings.length; j++) detach(bindings[j]);
      current = null;
    }

    var source = {
      name: name,
      start: start,
      stop: stop,
      equals: function (boundValue, observedValue) {
        if (observedValue === null) return !disconnectIsMismatch;
        return boundValue === observedValue;
      },
      current: snapshot,
      subscribe: function (fn) {
        if (typeof fn !== "function") throw new TypeError("SolanaStudio.walletIdentity: subscribe needs a function");
        subscribers.push(fn);
        return function () {
          var at = subscribers.indexOf(fn);
          if (at !== -1) subscribers.splice(at, 1);
        };
      },
      reconcile: function () {
        reconcile();
        return snapshot();
      },
      isRunning: function () { return running; }
    };
    if (typeof options.bound === "function") source.bound = options.bound;
    return source;
  }

  // create() plus registration with the session store. Without a store the
  // source still runs, so a page can render wallet state before, or without,
  // the session primitive.
  function register(options) {
    options = options || {};
    var session = options.session || W.StudioSession;
    var source = create(options);
    if (!session || typeof session.registerIdentitySource !== "function") {
      source.start();
      return { source: source, registration: null };
    }
    return { source: source, registration: session.registerIdentitySource(source) };
  }

  W.SolanaStudio.walletIdentity = {
    loaded: true,
    STATUSES: STATUSES.slice(),
    DEFAULTS: {
      name: DEFAULTS.name,
      discoveryMs: DEFAULTS.discoveryMs,
      discoveryIntervalMs: DEFAULTS.discoveryIntervalMs,
      trustedConnect: DEFAULTS.trustedConnect,
      disconnectIsMismatch: DEFAULTS.disconnectIsMismatch
    },
    create: create,
    register: register
  };
})(window);
