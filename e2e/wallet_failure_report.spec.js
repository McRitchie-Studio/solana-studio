// The two wallet modals' REPORTING seam, in a real browser, against the real
// partials — the only tier that can see it.
//
// WHY NOT A RUBY TEST. Every line under test here is inlined JavaScript inside
// an x-data attribute. A Ruby test can assert the characters shipped; it cannot
// run them, so it cannot tell a working guard from a negated one. Measured
// 2026-09-06 across two PRs in this ecosystem: 25 source-text mutants, 10
// survived, including a negated guard and a `throw` swapped for a console.warn.
// docs/agents/modules/modal-lifecycle.md carries the rule.
//
// FAIL-OPEN IS PROVED BY A REAL THROW, NOT A STUBBED SAD RESPONSE. The trap on
// the shipped half of this feature: `fetch()` RESOLVES on 4xx/5xx, so a spec
// that stubs a 500 and asserts the user path completes proves nothing — the
// error-swallowing can be deleted and the spec stays green. Four such specs did.
// Here the equivalent trap is different in shape and identical in kind: the
// reporter is HOST-supplied, so the failure the gem must survive is a host
// implementation that THROWS, and only a real throw exercises the gem's guard.
const { test, expect } = require("@playwright/test");

// The 2026-09-06 shape, and the reason both message halves are sent. `raw` is
// what the wallet said; the shipped mapper turns it into balance advice, which
// is what the user reads. With only the mapped half recorded, a MIS-mapping is
// invisible — which is exactly how this went unnoticed for a week.
const RAW = "Insufficient funds for transaction";
const MAPPED = "Insufficient USDC balance. Top up your wallet via the Faucet.";

async function rejectWith(page, { message, code = null, reported = false }) {
  await page.evaluate(
    ({ message, code, reported }) => {
      const err = new Error(message);
      if (code !== null) err.code = code;
      if (reported) err.walletFailureReported = true;
      window.labRejectWith = err;
    },
    { message, code, reported }
  );
}

const reports = (page) => page.evaluate(() => window.labReports);

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_failure");
});

// ── The wiring, both surfaces ───────────────────────────────────────────────

test("the picker reports stage wallet_connect with BOTH message halves", async ({ page }) => {
  await rejectWith(page, { message: RAW });
  await page.evaluate(() => window.labOpenPicker());
  await page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first().click();

  // The user is served first, and is served the MAPPED sentence.
  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);

  await expect.poll(() => reports(page)).toHaveLength(1);
  const [r] = await reports(page);

  expect(r.stage).toBe("wallet_connect");
  expect(r.provider).toBe("Phantom");
  // THE ASSERTION THIS FEATURE EXISTS FOR. Both halves, and DIFFERENT — a
  // report whose raw and mapped are byte-identical is the undiagnosable row.
  expect(r.raw).toBe(RAW);
  expect(r.mapped).toBe(MAPPED);
  expect(r.raw).not.toBe(r.mapped);
  // Four values and nothing else. `opts`, `verifyArgs()` and `this.props` are
  // all in scope at that call site and carry currentUserId.
  expect(r.arity).toBe(4);
});

test("the step-up card reports stage web3_step_up with BOTH message halves", async ({ page }) => {
  await rejectWith(page, { message: RAW });
  await page.evaluate(() => window.labOpenStepUp());
  await page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first().click();

  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);

  await expect.poll(() => reports(page)).toHaveLength(1);
  const [r] = await reports(page);

  expect(r.stage).toBe("web3_step_up");
  expect(r.provider).toBe("Phantom");
  expect(r.raw).toBe(RAW);
  expect(r.mapped).toBe(MAPPED);
  expect(r.raw).not.toBe(r.mapped);
  expect(r.arity).toBe(4);
});

// A 4001 decline is the one path where the card composes the sentence itself
// rather than taking the mapper's. The wallet's own words must still ride along,
// or the commonest rejection in the product reports our string in both halves.
test("a 4001 decline still reports the wallet's own words as raw", async ({ page }) => {
  await rejectWith(page, { message: "User rejected the request.", code: 4001 });
  await page.evaluate(() => window.labOpenPicker());
  await page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first().click();

  await expect.poll(() => reports(page)).toHaveLength(1);
  const [r] = await reports(page);

  expect(r.mapped).toBe("Signature rejected");
  expect(r.raw).toBe("User rejected the request.");
});

// ── Fail-open: a HOST reporter that throws ──────────────────────────────────

// THE WEDGE, and it is why the try/catch at the step-up call site is not
// decoration. `this.connecting = false` sits OUTSIDE that catch block, so a
// throw from the reporter skips it and the sign-in button stays disabled
// forever — with an error on screen the user cannot retry. Alpine swallows a
// throw out of an async handler, so nothing anywhere would say so.
//
// DELETE the try/catch around the report call in
// app/views/solana_studio/modals/_web3_step_up.html.erb and this goes red.
test("a host reporter that throws cannot wedge the step-up card", async ({ page }) => {
  await page.evaluate(() => {
    window.reportWalletFailure = function () { throw new TypeError("host reporter is broken"); };
  });
  await rejectWith(page, { message: RAW });
  await page.evaluate(() => window.labOpenStepUp());

  const button = page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first();
  await button.click();

  // The user still gets their error...
  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);
  // ...AND can still try again. This half is what the throw destroys.
  await expect(button).toBeEnabled();
});

// The same guard at the other call site. Its state assignments all sit INSIDE
// the catch, so a throw cannot wedge the card here — but it would still escape
// an async Alpine handler as an unhandled rejection, and the row would stay
// disabled behind `connecting` until the component re-rendered.
//
// DELETE the try/catch in _wallet_connect.html.erb and this goes red.
test("a host reporter that throws cannot wedge the picker", async ({ page }) => {
  const unhandled = [];
  page.on("pageerror", (e) => unhandled.push(e.message));

  await page.evaluate(() => {
    window.reportWalletFailure = function () { throw new TypeError("host reporter is broken"); };
  });
  await rejectWith(page, { message: RAW });
  await page.evaluate(() => window.labOpenPicker());

  const button = page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first();
  await button.click();

  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);
  await expect(button).toBeEnabled();
  expect(unhandled).toEqual([]);
});

// ── Fail-open: no reporter at all ───────────────────────────────────────────

// The `typeof` guard, which is the whole contract for a consumer that never
// built an endpoint. Absent reporter must mean SILENCE, never a TypeError —
// and a TypeError inside an Alpine handler is silent, so this cannot be left to
// inspection. NEGATE the guard (=== to !==) and this goes red.
test("no host reporter at all leaves the user path untouched", async ({ page }) => {
  const unhandled = [];
  page.on("pageerror", (e) => unhandled.push(e.message));

  await page.evaluate(() => { delete window.reportWalletFailure; });
  await rejectWith(page, { message: RAW });
  await page.evaluate(() => window.labOpenStepUp());

  const button = page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first();
  await button.click();

  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);
  await expect(button).toBeEnabled();
  expect(unhandled).toEqual([]);
});

// ── Not twice ───────────────────────────────────────────────────────────────

// solanaConnectAndVerify substitutes its own sentence for an unusable wallet and
// reports the pair from in there, where the wallet's words still exist, tagging
// the error it rethrows. Without the tag check the same failure files a SECOND
// row whose raw and mapped are both OUR sentence — the useless row, and the one
// an operator meets first. Drop `&& !(e && e.walletFailureReported)` and this
// goes red.
test("an error already reported upstream is not reported a second time", async ({ page }) => {
  await rejectWith(page, { message: RAW, reported: true });
  await page.evaluate(() => window.labOpenStepUp());
  await page.locator('[data-test="wallet-failure-lab"] button', { hasText: "Phantom" }).first().click();

  // The user is still served — suppressing the REPORT must not suppress the copy.
  await expect(page.locator('[data-test="wallet-failure-lab"] p[role="alert"]')).toHaveText(MAPPED);
  expect(await reports(page)).toHaveLength(0);
});
