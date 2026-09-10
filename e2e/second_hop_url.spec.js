// THE SECOND HOP, IN A REAL BROWSER.
//
// A phone found this and no test here could: hop one completed, hop two opened
// Phantom to its home screen, and a user's entry was lost after they had already
// approved it. The cause was a URL built with redirect_link silently dropped.
//
// The node suite now covers the same property, but it constructs the world by
// hand. What ONLY this tier can show is that the shipped files, delivered as real
// assets and run by a real JS engine, produce a well-formed request — and that
// the journal survives real browser storage between the hops.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_transport");
  await expect
    .poll(() => page.evaluate(() => typeof window.labSecondHopUrl))
    .toBe("function");
  await page.evaluate(() => window.labClearJournal());
});

test("the second hop carries a return address @smoke", async ({ page }) => {
  const url = await page.evaluate(() => window.labSecondHopUrl("phantom"));

  expect(url, "no second hop was produced at all").toBeTruthy();
  const params = new URL(url).searchParams;

  // THE REGRESSION. Without this the wallet has nowhere to send the signature.
  expect(params.get("redirect_link")).toBe(
    new URL(await page.evaluate(() => window.location.origin + "/lab/wallet_transport")).toString()
  );
});

test("the second hop carries everything a wallet needs @smoke", async ({ page }) => {
  // redirect_link is the field that bit us; the CLASS is "a field the resume
  // needed was not there". Assert the whole required set.
  const url = await page.evaluate(() => window.labSecondHopUrl("phantom"));
  const params = new URL(url).searchParams;

  for (const field of ["dapp_encryption_public_key", "nonce", "payload", "redirect_link"]) {
    expect(params.get(field), `second hop is missing ${field}`).toBeTruthy();
  }
});

test("every wallet carries it, not just Phantom", async ({ page }) => {
  // One code path serves three wallets, so a per-wallet regression is only real
  // if it is asserted per wallet.
  for (const wallet of ["phantom", "solflare", "backpack"]) {
    await page.evaluate(() => window.labClearJournal());
    const url = await page.evaluate((w) => window.labSecondHopUrl(w), wallet);
    expect(url, `${wallet} produced no second hop`).toBeTruthy();
    expect(
      new URL(url).searchParams.get("redirect_link"),
      `${wallet} lost the return address`
    ).toBeTruthy();
  }
});
