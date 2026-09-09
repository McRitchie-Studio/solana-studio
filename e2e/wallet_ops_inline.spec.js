// The INLINE transport's transaction contract, driven by the SHIPPED
// wallet_ops.js in a real browser.
//
// THE DIVISION OF LABOUR, same as the two specs beside this one. The node suite
// (test/wallet_ops_js_test.rb) owns the contract itself — both transports
// compared against each other, every refusal, the journal across simulated page
// deaths. This file must not restate them.
//
// WHAT ONLY THIS TIER CAN ANSWER. Two things, and neither is "the algorithm is
// right":
//
//   1. Does the inline path EXECUTE when a browser parses and runs the file a
//      consumer installs. It is a promise chain over a provider object, and a
//      node `require` is a different loader with different tolerances — the same
//      argument that put wallet_transport.spec.js here after a free variable at
//      module scope broke every mobile sign-in while eleven view tests stayed
//      green.
//
//   2. Whether the connected account survives being a REAL OBJECT. A
//      solanaWeb3.PublicKey is an object whose toString() is its base58 address,
//      and the gem reads it with `String(pk)` precisely so it can do that
//      without taking a web3.js dependency. The node suite passes plain strings,
//      because that is what a node harness has. This is the tier where the
//      object exists.
//
// The lab's adapter refuses to be lenient: its signTransaction THROWS on
// anything that is not an object, exactly as an injected wallet does. A
// regression that handed it base58 fails here rather than passing quietly.
const { test, expect } = require("@playwright/test");

test.beforeEach(async ({ page }) => {
  await page.goto("/lab/wallet_transport");
  await page.evaluate(() => window.labClearJournal());
});

test("the inline transport signs wire bytes and hands wire bytes back", async ({ page }) => {
  const result = await page.evaluate(() => window.labInlineRun("ok"));

  expect(result.outcome).toBe("ran");
  // A string, not the signed Transaction object the wallet returned. This is the
  // half that makes ONE call site possible on the return leg.
  expect(result.value.signedType).toBe("string");
  expect(result.value.signed).toBe("SIGNED-TXB58");
  // prepare's own state reaches complete untouched, so a handler reading
  // state.transaction gets the same type on both transports.
  expect(result.value.stateTx).toBe("TXB58");
  expect(result.value.slug).toBe("ptx-7");
  expect(result.value.sent).toBe("app-broadcasts");
  // Connect precedes prepare: prepare mints a server record, and a wrong wallet
  // must not cost one.
  expect(result.value.calls).toEqual(["connect", "prepare", "deserialize", "sign", "serialize"]);
});

test("an inline provider without the codec is refused before the wallet is touched", async ({ page }) => {
  const result = await page.evaluate(() => window.labInlineRun("noCodec"));

  expect(result.outcome).toBe("refused");
  expect(result.message).toContain("deserializeTransaction()");
  expect(result.message).toContain("base58 wire bytes");
  // Nothing ran — not connect, and certainly not prepare. A missing codec half
  // must never cost a wallet prompt.
  expect(result.calls).toEqual([]);
});

test("a wallet connecting as another account is refused, reading a real PublicKey object", async ({ page }) => {
  const result = await page.evaluate(() => window.labInlineRun("wrongAccount"));

  expect(result.outcome).toBe("refused");
  expect(result.message).toContain("Wrong wallet");
  // The addresses came off objects, through String(pk), with no web3.js in sight.
  expect(result.expected).toBe("GkxHc1Bv7pQm4RtyVn2ZcAeD8sWfLuJp3NoXaTgYkQrM");
  expect(result.connected).toBe("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM");
  expect(result.wrongAccount).toBe(true);
  // Refused after connect and BEFORE prepare — the whole reason connect runs first.
  expect(result.calls).toEqual(["connect"]);
});
