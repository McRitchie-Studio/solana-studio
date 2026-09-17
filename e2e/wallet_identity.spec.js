// The SHIPPED wallet identity source, in a real browser.
//
// THE DIVISION OF LABOUR. test/wallet_identity_js_test.rb owns the behaviour: 41
// node tests over fake wallets and manual timers, plus a StudioSession contract
// stub. This file must not re-prove those branches. What only a browser can answer:
//
//   1. does solana_studio/wallet_identity.js parse and execute when a page loads it;
//   2. does it find a provider that an extension-style init script put on window
//      before the page's own scripts, through its DEFAULT resolver;
//   3. do REAL timers run its discovery window: a wallet injected after load is
//      found, and a page with no wallet moves from `unknown` to `none`;
//   4. do its listeners, attached to a real Window and a real Document, repaint a
//      page when the wallet changes.
//
// WHAT THIS CANNOT SEE, measured rather than assumed (2026-09-17, Playwright 1.62.1):
// headless Chromium never hides a tab. page.bringToFront() on a second page and a
// CDP window minimize both left document.visibilityState "visible" and fired no
// visibilitychange, in the headless shell and in new headless alike. So the hidden
// tab below is EMULATED by shadowing document.visibilityState and dispatching the
// event. That still drives the shipped listener on a real Document; it does not
// prove a real tab switch, which remains an operator check with a real wallet.
const { test, expect } = require("@playwright/test");

const A = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU";
const B = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";

// Phantom's injected provider, installed the way the extension installs it: on
// window, before any page script runs.
function installPhantom(address) {
  const handlers = {};
  const key = (a) => ({ toBase58: () => a, toString: () => a });
  const provider = {
    isPhantom: true,
    name: "Phantom",
    publicKey: address ? key(address) : null,
    on: (event, fn) => { (handlers[event] = handlers[event] || []).push(fn); },
    off: (event, fn) => { handlers[event] = (handlers[event] || []).filter((f) => f !== fn); }
  };
  window.phantom = { solana: provider };
  window.labPhantomSwitch = (next) => {
    provider.publicKey = next ? key(next) : null;
    (handlers.accountChanged || []).slice().forEach((fn) => fn(provider.publicKey));
  };
}

// A raw Wallet Standard wallet factory. The spec decides WHEN it appears on
// window.labWallet, which is what a late registration looks like to the page.
function installStandardWalletFactory() {
  window.labMakeStandardWallet = (address) => {
    let listeners = [];
    const account = (a) => ({ address: a, publicKey: new Uint8Array(32), chains: ["solana:devnet"], features: [] });
    const wallet = {
      version: "1.0.0",
      name: "Solflare",
      icon: "data:image/svg+xml;base64,",
      chains: ["solana:devnet"],
      accounts: address ? [account(address)] : [],
      features: {
        "standard:events": {
          version: "1.0.0",
          on: (event, fn) => {
            if (event !== "change") return () => {};
            listeners.push(fn);
            return () => { listeners = listeners.filter((f) => f !== fn); };
          }
        }
      },
      userSwitches: (next) => {
        wallet.accounts = next ? [account(next)] : [];
        listeners.slice().forEach((fn) => fn({ accounts: wallet.accounts }));
      },
      switchesSilently: (next) => { wallet.accounts = next ? [account(next)] : []; }
    };
    return wallet;
  };
}

const status = (page) => page.locator('[data-test="wallet-status"]');

test("the shipped source executes and paints Phantom's injected wallet", async ({ page }) => {
  await page.addInitScript(installPhantom, A);
  await page.goto("/lab/wallet_identity");

  await expect(page.locator('[data-test="identity-loaded"]')).toHaveText("loaded");
  await expect(status(page)).toHaveText(`connected:${A}`);
  await expect(page.locator('[data-test="wallet-provider"]')).toHaveText("Phantom");

  await page.evaluate((next) => window.labPhantomSwitch(next), B);
  await expect(status(page)).toHaveText(`connected:${B}`);
  await page.evaluate(() => window.labPhantomSwitch(null));
  await expect(status(page)).toHaveText("disconnected");

  expect(await page.evaluate(() => window.labReports)).toEqual([A, B, null]);
});

test("a page with no wallet reads unknown, then none when the real discovery window closes", async ({ page }) => {
  await page.goto("/lab/wallet_identity?provider=lab");

  await expect(page.locator('[data-test="identity-loaded"]')).toHaveText("loaded");
  // Read once, straight after load: the window is 3 seconds, so this is the
  // state a navbar paints first, and it must not claim there is no wallet.
  expect(await status(page).textContent()).toBe("unknown");
  expect(await page.evaluate(() => window.labReports)).toEqual([]);

  await expect(status(page)).toHaveText("none", { timeout: 8000 });
  expect(await page.evaluate(() => window.labReports)).toEqual([null]);
});

test("a wallet registered after load is found by the discovery timer and repaints on change", async ({ page }) => {
  await page.addInitScript(installStandardWalletFactory);
  await page.goto("/lab/wallet_identity?provider=lab");
  expect(await status(page).textContent()).toBe("unknown");

  await page.evaluate((address) => { window.labWallet = window.labMakeStandardWallet(address); }, A);
  await expect(status(page)).toHaveText(`connected:${A}`, { timeout: 8000 });
  await expect(page.locator('[data-test="wallet-provider"]')).toHaveText("Solflare");

  await page.evaluate((next) => window.labWallet.userSwitches(next), B);
  await expect(status(page)).toHaveText(`connected:${B}`);
  await page.evaluate(() => window.labWallet.userSwitches(null));
  await expect(status(page)).toHaveText("disconnected");

  expect(await page.evaluate(() => window.labReports)).toEqual([A, B, null]);
});

test("a switch the wallet never announced is caught when the page is shown again or refocused", async ({ page }) => {
  await page.addInitScript(installStandardWalletFactory);
  await page.addInitScript((address) => {
    window.labWallet = window.labMakeStandardWallet(address);
  }, A);
  await page.goto("/lab/wallet_identity?provider=lab");
  await expect(status(page)).toHaveText(`connected:${A}`);

  // Hidden (emulated; see the header), then a switch with no event.
  await page.evaluate((next) => {
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
    document.dispatchEvent(new Event("visibilitychange"));
    window.labWallet.switchesSilently(next);
  }, B);
  // The source reacts synchronously, so a direct read is the state after the event.
  expect(await status(page).textContent()).toBe(`connected:${A}`);

  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await expect(status(page)).toHaveText(`connected:${B}`);

  // A second unannounced switch, recovered by a focus event on the real Window.
  await page.evaluate((next) => {
    window.labWallet.switchesSilently(next);
    window.dispatchEvent(new FocusEvent("focus"));
  }, A);
  await expect(status(page)).toHaveText(`connected:${A}`);

  expect(await page.evaluate(() => window.labReports)).toEqual([A, B, A]);
});
