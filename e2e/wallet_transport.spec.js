// The SHIPPED redirect transport, in a real browser.
//
// THE DIVISION OF LABOUR, stated so nobody adds string assertions here. The node
// suites (test/wallet_transport_js_test.rb, redirect_provider_js_test.rb,
// wallet_ops_js_test.rb) own the protocol: 38 tests, real tweetnacl, every
// per-wallet divergence driven across all three wallets. They are the right tier
// for that and this one must not duplicate them.
//
// What ONLY this tier can answer is two things, and both are here:
//   1. do the four shipped files parse and execute when a browser loads them;
//   2. does the journal survive a REAL navigation — the page destruction the
//      entire design exists to survive, staged for once with an actual browser
//      rather than a hash a test kept alive.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_transport");
  await page.evaluate(() => window.labClearJournal());
});

// A script swallowed by a phantom element, an ERB comment that terminated early,
// a syntax error a node require tolerated — each leaves this MISSING and each is
// invisible to every non-browser tier. Named per module so the failure says which.
test("all four shipped modules parse and execute in a browser", async ({ page }) => {
  await page.reload();
  await expect(page.locator('[data-test="modules-loaded"]')).toHaveText("loaded");
});

// Built by the shipped URL builder inside a browser, not by a node stub. Proves
// the per-wallet profile survives asset delivery — a truncated file would still
// define the namespace while losing the table.
test("the provider builds a real connect URL for each wallet", async ({ page }) => {
  const urls = await page.evaluate(() =>
    ["phantom", "solflare", "backpack"].map((w) => window.labBeginConnect(w))
  );

  expect(urls[0]).toContain("https://phantom.app/ul/v1/connect?");
  expect(urls[1]).toContain("https://solflare.com/ul/v1/connect?");
  expect(urls[2]).toContain("https://backpack.app/ul/v1/connect?");
  // The cluster the LAB publishes on <body>, carried through to the wallet.
  expect(urls[0]).toContain("cluster=devnet");
  // The dapp key must be present on every one — without it the wallet has
  // nothing to build a shared secret from and the trip cannot complete.
  urls.forEach((u) => expect(u).toContain("dapp_encryption_public_key="));
});

// THE ONE THIS WHOLE FILE EXISTS FOR. Save a journal, LEAVE the page entirely,
// come back, and read it through the shipped journal. Everything in the node
// suites simulates this with JSON; here the document is genuinely destroyed and
// rebuilt by the browser, which is the only place the assumption can be wrong.
test("the journal survives a real navigation away and back", async ({ page }) => {
  await page.evaluate(() => window.labBeginConnect("phantom"));

  await page.click('[data-test="leave"]');
  await expect(page.locator('[data-test="guard-lab"]')).toBeVisible();

  await page.goto("/lab/wallet_transport");

  // Read back through the gem's own journal on a freshly built document.
  await expect(page.locator('[data-test="journal-after-return"]')).toHaveText("phantom:connect");
});

// The other half of that contract: a cleared journal reads as nothing pending on
// the next document, so an abandoned trip cannot be resumed by a later visit.
test("a cleared journal reports nothing pending after a navigation", async ({ page }) => {
  await page.evaluate(() => window.labBeginConnect("phantom"));
  await page.evaluate(() => window.labClearJournal());

  await page.goto("/lab/wallet_transport");

  await expect(page.locator('[data-test="journal-after-return"]')).toHaveText("none");
});
