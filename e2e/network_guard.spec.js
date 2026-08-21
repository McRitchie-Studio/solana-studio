// The SHIPPED guard, in a real browser.
//
// Every assertion here drives window.SolanaStudio.network — the file
// e2e/boot.rb copied out of app/assets, byte for byte what a consumer installs.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/guard");
});

// THE ONE THING NO OTHER TIER CAN ANSWER. The node suite proves the classifier's
// string matching; it cannot prove the file parses and executes when a browser
// loads it. An ERB comment that terminated early, a stray byte, a syntax error a
// bundler tolerated — each leaves this "MISSING" and is invisible everywhere else.
// This exact failure shape (a script that never ran, green in every tier) is one
// of the three defects that motivated the ecosystem's browser-evidence gate.
test("the shipped guard parses and executes in a browser", async ({ page }) => {
  await expect(page.locator('[data-test="guard-loaded"]')).toHaveText("loaded");
});

// The server's Solana::Network.describe reaches the browser and the guard reads
// it. Asserted through the guard's own context() rather than by re-parsing the
// attribute, because the contract under test is that THE GUARD can read what a
// host publishes — not that JSON round-trips.
test("the guard reads the host's published network context", async ({ page }) => {
  const ctx = await page.evaluate(() => window.SolanaStudio.network.context());

  expect(ctx.cluster).toBe("devnet");
  expect(ctx.label).toBe("Devnet");
  expect(ctx.environmentLabel).toBe("QA");
  expect(ctx.walletStandardChain).toBe("solana:devnet");
});

// A real rejection travelling through the real promise wrapper. The node suite
// stubs both; here the browser's own microtask queue runs it.
test("guard re-throws the original error and still hints", async ({ page }) => {
  const message =
    "Transaction simulation failed: Attempt to load a program that does not exist";
  const rethrown = await page.evaluate((m) => window.labRun(m), message);

  expect(rethrown).toBe(message);

  const out = page.locator('[data-test="result"]');
  await expect(out).toHaveAttribute("data-rethrown", message);

  const hint = JSON.parse(await out.getAttribute("data-hint"));
  expect(hint.confidence).toBe("likely");
  expect(hint.networkLabel).toBe("Devnet");
  expect(hint.originalMessage).toBe(message);
});

// The under-claim guarantee, end to end: an ordinary business rejection must not
// fire the hint at all. This is the inversion that shipped and was caught in
// review — a full contest telling the user to change their wallet's network.
test("an ordinary program error never hints", async ({ page }) => {
  const message =
    "Transaction simulation failed: Error processing Instruction 0: custom program error: 0x1770";
  const rethrown = await page.evaluate((m) => window.labRun(m), message);

  expect(rethrown).toBe(message);

  const out = page.locator('[data-test="result"]');
  await expect(out).toHaveAttribute("data-rethrown", message);
  expect(await out.getAttribute("data-hint")).toBeNull();
});
