// An intent's sign-only declaration, honoured by the SHIPPED wallet_ops.js in a
// real browser.
//
// THE DIVISION OF LABOUR, same as wallet_transport.spec.js. The node suite
// (test/wallet_ops_js_test.rb) owns the protocol — both branches across all three
// wallets, the journal across two simulated page deaths, a callback page with no
// intent registered. Those are the right tier and this file must not restate them.
//
// What ONLY this tier can answer: does the branch EXECUTE when a browser parses
// and runs the file a consumer installs. A node `require` is a different loader
// with different tolerances, and the choice made here decides where a user's
// phone is sent — so "the algorithm is right" and "the shipped bytes run" are
// separate claims, and a co-signed transaction handed to a wallet's broadcaster
// is rejected on chain with no signed bytes to retry from.
//
// Both branches are driven per wallet, because a change that routed EVERYTHING
// to signTransaction would satisfy the sign-only half alone.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_transport");
  await page.evaluate(() => window.labClearJournal());
});

// Solflare and Backpack both CAN broadcast, and before this branch existed they
// both would have. Phantom is here because a wallet that never had the send-side
// deeplink must not quietly become the only evidence.
test("a declared sign-only intent reaches signTransaction on every wallet", async ({ page }) => {
  const urls = await page.evaluate(() =>
    Promise.all(["phantom", "solflare", "backpack"].map((w) => window.labSigningHop(w, true)))
  );

  expect(urls[0]).toContain("https://phantom.app/ul/v1/signTransaction?");
  expect(urls[1]).toContain("https://solflare.com/ul/v1/signTransaction?");
  expect(urls[2]).toContain("https://backpack.app/ul/v1/signTransaction?");
  urls.forEach((u) => expect(u).not.toContain("signAndSendTransaction"));
});

// The other branch, and the acceptance criterion it belongs to: an intent that
// declares nothing is routed exactly as it was before the option existed.
test("an undeclared intent still reaches the wallet's own broadcaster", async ({ page }) => {
  const urls = await page.evaluate(() =>
    Promise.all(["phantom", "solflare", "backpack"].map((w) => window.labSigningHop(w, null)))
  );

  // Phantom deprecated its send-side deeplink, so it signs and the app sends.
  expect(urls[0]).toContain("https://phantom.app/ul/v1/signTransaction?");
  expect(urls[1]).toContain("https://solflare.com/ul/v1/signAndSendTransaction?");
  expect(urls[2]).toContain("https://backpack.app/ul/v1/signAndSendTransaction?");
});
