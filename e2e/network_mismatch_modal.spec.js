// The SHIPPED modal partial, rendered through studio-engine's real modal host,
// painted by real Alpine, in a real browser.
//
// This is the half no Ruby tier reaches. test/views_test.rb proves the template
// COMPILES; it cannot render it, because rendering needs the engine's modal
// blocks and a view context. So until this lane existed, the only evidence that
// the card paints anything was that its ERB parsed.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/modal");
});

// The whole chain in one assertion: an error string a wallet actually emits →
// the real classifier → the real props → the real partial → pixels. Every step
// is the shipped article; the lab supplies only the trigger.
test("a wrong-network failure opens the modal and paints its facts", async ({ page }) => {
  const message =
    "Transaction simulation failed: Attempt to load a program that does not exist";
  const hint = await page.evaluate((m) => window.labOpenFor(m), message);

  expect(hint).not.toBeNull();
  expect(hint.confidence).toBe("likely");

  const card = page.locator('[data-test="modal-lab"]');
  await expect(card).toContainText("Check your wallet's network");

  // The two facts the modal exists to state, painted from the server's own
  // Solana::Network.describe rather than hard-coded in the page.
  await expect(card).toContainText("This app runs on");
  await expect(card).toContainText("Devnet");
  await expect(card).toContainText("QA");
});

// THE DESIGN PROMISE, asserted where it can actually be observed: the hint sits
// BESIDE the wallet's real error, never in place of it. A classifier that
// misreads an error must not also swallow it — that would be a worse bug than
// the confusion the modal exists to clear up.
test("the modal still carries the wallet's own error text", async ({ page }) => {
  const message =
    "Transaction simulation failed: Attempt to load a program that does not exist";
  await page.evaluate((m) => window.labOpenFor(m), message);

  // It lives behind a <details>; open it the way a user would.
  await page.locator('[data-test="modal-lab"] details summary').click();
  await expect(page.locator('[data-test="modal-lab"] details')).toContainText(message);
});

// The other side of the under-claim rule, at the surface a person sees: an
// ordinary business rejection must leave the modal shut. Asserted through the
// same entry point, so the two outcomes are compared on one path.
test("an ordinary program error leaves the modal shut", async ({ page }) => {
  const hint = await page.evaluate(
    (m) => window.labOpenFor(m),
    "Transaction simulation failed: Error processing Instruction 0: custom program error: 0x1770"
  );

  expect(hint).toBeNull();
  await expect(page.locator('[data-test="modal-lab"]')).not.toContainText(
    "Check your wallet's network"
  );
});
