// The picker's mobile rows, in a real browser on a phone's user agent.
//
// THE DEFECT, live until 2026-09-07: on a phone, Solflare and Backpack were
// offered their DESKTOP EXTENSION download pages — solflare.com/download — a
// dead end with no error, for two wallets that each ship a full deeplink
// protocol. The picker's canDeepLink asked whether ONE Phantom-specific global
// existed, so no other wallet could answer yes.
//
// WHAT THIS TIER ADDS over test/views/wallet_picker_mobile_handoff_test.rb,
// which evaluates the same getters under node: that the rows actually PAINT.
// The row list being right and the list reaching the screen are different
// claims — an x-for over the wrong key, a template Alpine never walks, a
// brandIcon that resolves to nothing all leave the getters correct and the
// modal empty. And only here does the real redirect_provider.js supply the
// list, rather than a stub of it.
const { test, expect } = require("@playwright/test");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

async function openPicker(page) {
  await page.goto("/lab/wallet_failure");
  await expect
    .poll(() => page.evaluate(() => typeof window.SolanaStudio?.redirectProvider?.all))
    .toBe("function");
  await page.evaluate(() => window.labOpenPicker());
}

// Every row the picker paints, as [label, action-kind]. Read off the DOM rather
// than off the component, because "the getter returned it" is the claim the node
// tier already owns.
async function rows(page) {
  return page.$$eval("[x-data] button, [x-data] a", (els) =>
    els
      .map((el) => {
        const name = el.querySelector("span.font-semibold")?.textContent?.trim();
        if (!name) return null;
        const label = el.querySelector("span.uppercase")?.textContent?.trim();
        return { name, label, href: el.getAttribute("href") };
      })
      .filter(Boolean),
  );
}

test.describe("on a phone", () => {
  test.use({ userAgent: IPHONE });

  test("Solflare and Backpack are offered a way in, not a download page @smoke", async ({ page }) => {
    await openPicker(page);

    const painted = await rows(page);
    const byName = Object.fromEntries(painted.map((r) => [r.name, r]));

    // THE FIX: both now carry an actionable row.
    expect(byName.Solflare, "Solflare must appear on a phone").toBeTruthy();
    expect(byName.Backpack, "Backpack must appear on a phone").toBeTruthy();
    expect(byName.Solflare.label).toBe("Open app");
    expect(byName.Backpack.label).toBe("Open app");

    // THE DEFECT: neither may still be an anchor to a desktop download page.
    expect(byName.Solflare.href, "a phone cannot install a browser extension").toBeNull();
    expect(byName.Backpack.href).toBeNull();
  });

  test("the handoff navigates into the wallet's own browser", async ({ page }) => {
    await openPicker(page);

    // Capture the navigation rather than stubbing location — Chromium refuses to
    // redefine location.href, and watching the request is what actually happens.
    const navigation = page.waitForRequest((r) => r.url().includes("solflare.com/ul/"), {
      timeout: 15000,
    });
    await page.getByRole("button", { name: /Solflare/ }).click();

    const url = new URL((await navigation).url());
    expect(url.pathname).toContain("/ul/v1/browse/");
    // The target is THIS page, so the user lands where they already were.
    expect(decodeURIComponent(url.pathname)).toContain("/lab/wallet_failure");
    expect(url.searchParams.get("ref")).toBeTruthy();
  });
});

test("a desktop keeps its install rows and gets no handoffs", async ({ page }) => {
  await openPicker(page);

  const painted = await rows(page);
  const solflare = painted.find((r) => r.name === "Solflare");

  // On a desktop the download page is the CORRECT advice — this browser can
  // host an extension. The row must still be an anchor to it.
  expect(solflare).toBeTruthy();
  expect(solflare.label).toBe("Install");
  expect(solflare.href).toContain("solflare.com/download");
});
