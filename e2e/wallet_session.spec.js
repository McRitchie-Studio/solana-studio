// The PERSISTED wallet session, in a real browser.
//
// THE DIVISION OF LABOUR, same rule as wallet_transport.spec.js and
// wallet_ops_sign_only.spec.js. The node suite (test/wallet_ops_js_test.rb) owns
// the record, the scope, the refusal recovery and every branch of it — 20 tests
// over real tweetnacl and simulated page deaths. This file must not restate any
// of that.
//
// What ONLY this tier can answer is the part the whole feature rests on: that a
// session written by the shipped store SURVIVES A REAL PAGE DESTRUCTION in real
// browser localStorage, on the same trip where the journal deliberately does
// not — and that the shipped walletOps actually reaches signTransaction on the
// bytes a consumer installs. A node shim keeps a hash alive and calls that a
// page death; a browser genuinely throws the document away.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_transport");
  // Both records, so nothing below inherits state from a previous spec.
  await page.evaluate(() => window.labPurge());
});

// THE TWO LIFETIMES, STAGED FOR ONCE WITH AN ACTUAL BROWSER. The journal is
// single-use by design: take() clears it so a double-fired callback cannot
// advance a step twice. The session is the opposite and must outlive exactly
// that. Share one record and this reads "none" — which is the two-app-switch
// behaviour the feature exists to remove, and it would look perfectly fine in
// every node suite that kept the store in a variable.
test("a session outlives the journal it was established on, across a real navigation", async ({ page }) => {
  // remember() reports whether the write actually stuck. Discarding it lets a
  // quota or private-mode refusal surface later as a confusing recall miss, in a
  // spec about something else.
  expect(await page.evaluate(() => window.labRememberSession())).toBe(true);
  await page.evaluate(() => window.labBeginConnect("phantom"));

  // The completed trip takes its journal, exactly as a callback page does.
  const hadJournal = await page.evaluate(() => window.labTakeJournal());
  expect(hadJournal).toBe(true);

  // LEAVE the page entirely, then come back to a freshly built document.
  await page.click('[data-test="leave"]');
  await expect(page.locator('[data-test="guard-lab"]')).toBeVisible();
  await page.goto("/lab/wallet_transport");

  await expect(page.locator('[data-test="journal-after-return"]')).toHaveText("none");
  await expect(page.locator('[data-test="session-after-return"]')).toHaveText("LABADDR:LABSESSION");
});

// THE ACCEPTANCE CRITERION, EXECUTING. No session is handed to run(): reaching
// signTransaction is only possible if the shipped walletOps recalled the stored
// one. Solflare is driven in the same breath because it has no stored session,
// so a change that returned a session for any scope would satisfy the first
// assertion alone.
test("a returning user goes straight to signing, and an unknown wallet still connects", async ({ page }) => {
  expect(await page.evaluate(() => window.labRememberSession())).toBe(true);

  const warm = await page.evaluate(() => window.labWarmTrip("phantom"));
  const cold = await page.evaluate(() => window.labWarmTrip("solflare"));

  expect(warm).toContain("https://phantom.app/ul/v1/signTransaction?");
  expect(warm).not.toContain("/connect?");
  expect(cold).toContain("https://solflare.com/ul/v1/connect?");
});

// The safety half, in the store a logout actually has to clear. purge() sweeps
// by key prefix, so a session filed outside that prefix would leave this reading
// LABADDR:LABSESSION after a sign-out — a stranger at this browser offered a
// one-hop signature with a wallet session they never established.
test("a logout clears the session from real browser storage", async ({ page }) => {
  // The readout is painted once, on load. Asserting "none" against it BEFORE a
  // reload would only prove that remember() does not repaint the page, which is
  // true of every possible implementation — so the setup is asserted through
  // remember()'s own return value instead, and the readout is only read on a
  // document that was built after the write.
  expect(await page.evaluate(() => window.labRememberSession())).toBe(true);

  await page.goto("/lab/wallet_transport");
  await expect(page.locator('[data-test="session-after-return"]')).toHaveText("LABADDR:LABSESSION");

  await page.evaluate(() => window.labPurge());
  await page.goto("/lab/wallet_transport");

  await expect(page.locator('[data-test="session-after-return"]')).toHaveText("none");
});
