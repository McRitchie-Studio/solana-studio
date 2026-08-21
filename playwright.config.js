// The solana-studio BROWSER LANE.
//
// WHY A GEM HAS ONE. This gem ships an imperative browser program —
// app/assets/javascripts/solana_studio/network_guard.js — and an ERB partial that
// no Ruby tier can render. During the review that introduced them, FIVE defects
// were found, and every one survived a green suite:
//
//   · a wrapper in the high-confidence list, so a plain "contest is full" told the
//     user to change their wallet's network — the feature inverted;
//   · the fix for it put a DIFFERENT wrapper at higher precedence, silencing the
//     real signal — explain() returned null and the modal never opened;
//   · the regression test written for that measured a string Solana does not emit;
//   · the under-claim test asserted a bare "0x1774", a shape no wallet sends;
//   · an ordering test varied two things at once and could not isolate either.
//
// Node stubs caught none of them; executing the file against real envelopes caught
// all of them. That is the argument for this lane, and it is why the specs here
// drive the SHIPPED bytes rather than a re-typed copy.
//
// ================= ONE BROWSER, AND WHAT THAT CANNOT SEE =================
//
// Chromium only. The classifier is string matching over error text, which is
// engine-independent — a regex that matches in V8 matches in JSC and SpiderMonkey.
// What this lane adds over node is not cross-engine coverage: it is whether the
// script PARSES AND RUNS in a browser at all, whether the promise wrapper behaves
// when a real rejection travels through it, and whether the partial's Alpine
// bindings actually paint. None of those is engine-specific either, so one engine
// answers them. A second would cost wall-clock and tell us nothing new.
//
// WHAT IT STILL CANNOT SEE, stated rather than implied: a real wallet. Phantom
// does not expose its selected network, so no lane can assert the mismatch the
// feature explains — only that the explanation renders when asked. Confirming
// Phantom's actual chainId behavior remains an operator act against QA.
module.exports = {
  testDir: "./e2e",
  // Deterministic order and no cross-spec interference. The lab has no database
  // and no shared state, so workers:1 costs almost nothing here and removes a
  // whole class of flake from a lane whose job is to be believed.
  workers: 1,
  fullyParallel: false,
  // A retry hides exactly the intermittency this lane exists to surface.
  retries: 0,
  reporter: [["list"], ["json", { outputFile: "tmp/e2e-report.json" }]],
  use: {
    baseURL: "http://127.0.0.1:3640",
    trace: "retain-on-failure"
  },
  projects: [{ name: "chromium", use: { browserName: "chromium" } }],
  webServer: {
    command: "bundle exec ruby e2e/boot.rb",
    url: "http://127.0.0.1:3640/lab/guard",
    reuseExistingServer: !process.env.CI,
    timeout: 120000
  }
};
