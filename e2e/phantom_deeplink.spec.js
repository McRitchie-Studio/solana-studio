// The Phantom MOBILE deep link, in a real browser.
//
// PORTED from studio-engine's e2e/phantom_deeplink.spec.js, deleted by
// drop-engine-web3-modals when the engine's web3 UI moved into this gem. The
// partial came here; its browser coverage did not, and for a while this existed in
// neither repo. The intent is carried over; the assertions are sharper, because the
// gem's structure allows a stronger question to be asked (see spec two).
//
// WHY THIS CANNOT BE A MARKUP TEST, in two parts.
//
// 1. THE SCRIPT HAS TO PARSE. solana_studio/_phantom_deeplink carries an INLINED
//    base58 encoder, inlined because turf-monster's copy reached it through a
//    second global (window.encodeBase58) that no other consumer has. A syntax or
//    scoping error anywhere in that IIFE is completely invisible to a String
//    assertion — the bytes are identical either way — and the failure lands at the
//    moment a user taps Connect on a phone. The assignment to
//    window.startPhantomDeepLink is the LAST statement in the IIFE, so its presence
//    in a real browser is proof the whole program parsed and ran.
//
// 2. THE ENCODER HAS TO BE RIGHT, not merely present. This is signature-critical:
//    the deep link encodes the SIWS input the user signs inside Phantom. An encoder
//    that silently mis-encodes produces a signature over the wrong bytes, which
//    fails verification server-side and reads to the user as a rejected wallet.
//    Asserting the emitted parameter merely LOOKS like base58 would pass over that.
//    So this file decodes it and compares the bytes.
//
// WHAT IS NOT COVERED HERE, stated rather than left as a silent gap: the picker's
// canDeepLink gate. It reaches its answer through window.walletProvider.isMobile,
// which turf-monster ships and this gem does not, so driving it here would mean
// stubbing the very thing that decides — the lab grading itself. That branch is
// browser-covered where it actually runs, in turf-monster's e2e/auth_modal.spec.js
// phone describe, which taps the row and decodes the payload independently.
const { test, expect } = require("@playwright/test");

// ── THE MEASURING INSTRUMENT ──────────────────────────────────────────────────
//
// A base58 DECODER, written here and deliberately not shared with the encoder it
// judges. Two independent implementations agreeing is evidence; one implementation
// agreeing with itself is not. This is the same discipline turf-monster's spec
// applies to the same partial, for the same reason.
const B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function decodeBase58(str) {
  const bytes = [0];
  for (const ch of str) {
    const value = B58_ALPHABET.indexOf(ch);
    if (value === -1) throw new Error(`not base58: ${ch}`);
    let carry = value;
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j] * 58;
      bytes[j] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }
  for (let k = 0; k < str.length - 1 && str[k] === "1"; k++) bytes.push(0);
  return Uint8Array.from(bytes.reverse());
}

// Uncaught errors from the page itself. A program that throws while defining the
// entry point can still leave a previously-defined one lying around, so the specs
// below assert the absence of page errors alongside the positive result.
function watchPageErrors(page) {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  return errors;
}

// The keypair nacl is stubbed to return. Distinct constant bytes, so a decode can
// assert WHICH buffer was encoded rather than only that something was.
const STUB_PUBLIC_KEY = 7;
const STUB_SECRET_KEY = 9;

async function stubTheFlow(page) {
  // nacl is the one dependency this lane cannot load — solana_studio/deeplink_assets
  // fetches tweetnacl from a CDN and the lane never reaches offsite. Stub the two
  // members the flow touches; everything else it drives — the inlined base58
  // encoder, the SIWS assembly, the localStorage handoff — is the real shipped
  // program.
  await page.addInitScript(
    ([pub, sec]) => {
      window.nacl = {
        box: {
          keyPair: () => ({
            publicKey: new Uint8Array(32).fill(pub),
            // 32, not 64. nacl.box is X25519, whose secret key is 32 bytes
            // (nacl.box.secretKeyLength === 32); 64 is nacl.SIGN's shape, and
            // real nacl.box.before REJECTS it with "bad secret key size". The
            // stub asserts nothing about this buffer today, but a stub that
            // lies about the shape of what it replaces is how a later spec
            // gets written against bytes the real flow can never produce.
            secretKey: new Uint8Array(32).fill(sec),
          }),
        },
      };
    },
    [STUB_PUBLIC_KEY, STUB_SECRET_KEY],
  );

  // The dummy host serves no auth routes; the deep link fetches a nonce before it
  // can build the payload.
  await page.route("**/auth/solana/nonce", (route) =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ nonce: "abc123" }),
    }),
  );

  // Keep the hand-off from actually leaving for phantom.app. The navigation still
  // happens and is still observable; it just lands on a stub.
  await page.route("https://phantom.app/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "<!doctype html><title>phantom</title>" }),
  );
}

test.describe("phantom deep link", () => {
  test("the inlined program parses and defines the entry point", async ({ page }) => {
    const errors = watchPageErrors(page);
    await page.goto("/lab/phantom_deeplink?deeplink=1");

    // Prove we are on the page we meant to be on, in the state we meant. Without
    // this a redirect, a 404 body, or a mis-typed route would let every assertion
    // below describe some other document entirely.
    await expect(page.locator('[data-test="deeplink-state"]')).toHaveAttribute("data-deeplink", "true");

    // THE BARE IDENTIFIER, which is what the consumer actually evaluates: the
    // picker's canDeepLink getter reads `typeof startPhantomDeepLink`, not
    // `typeof window.startPhantomDeepLink`. Asserting the window property alone
    // would pass over a future change that defined it somewhere the picker's
    // scope chain cannot reach.
    await expect.poll(() => page.evaluate(() => typeof startPhantomDeepLink)).toBe("function");
    expect(await page.evaluate(() => typeof window.startPhantomDeepLink)).toBe("function");

    expect(errors).toEqual([]);
  });

  test("calling it hands off to Phantom with a byte-exact base58 payload", async ({ page }) => {
    // THE INSTRUMENT CHECK, first and against a known-good pair, so a later
    // assertion failure can be read as "the encoder is wrong" rather than "the
    // decoder might be". This vector is the canonical one and was confirmed
    // against an independent bignum implementation before it was written here.
    expect(new TextDecoder().decode(decodeBase58("2NEpo7TZRRrLZSi2U"))).toBe("Hello World!");

    const errors = watchPageErrors(page);
    await stubTheFlow(page);
    await page.goto("/lab/phantom_deeplink?deeplink=1");
    await expect(page.locator('[data-test="deeplink-state"]')).toHaveAttribute("data-deeplink", "true");

    const origin = await page.evaluate(() => window.location.origin);
    const host = await page.evaluate(() => window.location.host);

    // CALLING IT, which is the whole point. The engine's earlier version checked
    // `typeof startPhantomDeepLink` and never invoked it — and a free variable
    // resolves at CALL time, so an encoder referencing an undefined constant
    // parses perfectly and defines the entry point. That exact defect shipped:
    // B58_ALPHABET was left at module scope while the body was inlined into a
    // classic script, and every mobile sign-in threw on the first keypair encode
    // with eleven view tests and a typeof check all green. A parse-time mutation
    // cannot reach that class either. Only calling it can.
    //
    // Capture the NAVIGATION rather than stubbing window.location — Chromium
    // refuses to redefine location.href, and watching the request is closer to
    // what actually happens anyway.
    const navigation = page.waitForRequest(
      (r) => r.url().startsWith("https://phantom.app/ul/v1/signIn"),
      { timeout: 15000 },
    );
    await page.evaluate(() => window.startPhantomDeepLink(false, null));
    const target = new URL((await navigation).url());
    const params = target.searchParams;

    expect(`${target.origin}${target.pathname}`).toBe("https://phantom.app/ul/v1/signIn");

    // ── The encryption key, decoded to bytes ──────────────────────────────────
    //
    // The sharpest assertion available: nacl was stubbed to a known 32-byte
    // buffer, so the emitted parameter must decode back to exactly those bytes.
    // A charset regex — which is all the engine's version could assert — is
    // satisfied by any encoder that emits plausible characters, including one
    // that drops a leading zero, reverses its digits, or truncates.
    const emittedKey = params.get("dapp_encryption_public_key");
    const decodedKey = Array.from(decodeBase58(emittedKey));
    expect(decodedKey).toEqual(new Array(32).fill(STUB_PUBLIC_KEY));

    // NEGATIVE CONTROL for the comparison above. Change one character of the
    // encoder's output and the same probe must reject it — otherwise "the bytes
    // matched" would be a statement about the assertion rather than the encoder.
    const lastChar = emittedKey.slice(-1);
    const tampered = emittedKey.slice(0, -1) + (lastChar === "2" ? "3" : "2");
    expect(Array.from(decodeBase58(tampered))).not.toEqual(decodedKey);

    // ── The signed payload, decoded and parsed ────────────────────────────────
    //
    // This is the buffer the user's signature covers. Mis-encode it and the
    // signature is over the wrong bytes: verification fails server-side and the
    // user sees a rejected wallet with nothing in the log. JSON.parse succeeding
    // at all is a real proof — a corrupted encode yields bytes that are not UTF-8
    // JSON — and the field assertions pin what was actually signed.
    const siws = JSON.parse(new TextDecoder().decode(decodeBase58(params.get("payload"))));

    expect(siws.domain).toBe(host);
    expect(siws.uri).toBe(origin);
    expect(siws.version).toBe("1");
    expect(siws.nonce).toBe("abc123");
    expect(siws.statement).toEqual(expect.any(String));
    expect(siws.statement.length).toBeGreaterThan(0);
    // Login mode, so no OPSEC-005 binding line — that is added only when linking a
    // wallet to a signed-in user.
    expect(siws.statement).not.toContain("User-ID:");
    expect(Number.isNaN(Date.parse(siws.issuedAt))).toBe(false);

    // ── The rest of the hand-off ──────────────────────────────────────────────
    //
    // The cluster the lab publishes on <body data-solana-cluster>, reaching the
    // link. A consumer that omits it signs against devnet while its wallet is on
    // mainnet, which reads as a rejected signature and logs nothing.
    expect(params.get("cluster")).toBe("devnet");
    expect(params.get("app_url")).toBe(origin);
    expect(params.get("redirect_link")).toBe(`${origin}/auth/phantom/callback`);

    expect(errors).toEqual([]);
  });

  // THE NEGATIVE CONTROL for the probe the first spec uses. Same lab, same layout,
  // same load, same evaluation — only the partial is absent. If that probe were
  // measuring something ambient rather than this partial's program, it would read
  // "function" here too and the first spec would be worthless. It reads "undefined",
  // so the probe discriminates.
  //
  // It is also the property the picker depends on: a consumer that does not render
  // the partial must NOT paint a mobile Phantom row, because the row's tap would
  // call a function that does not exist.
  test("a page without the partial defines nothing", async ({ page }) => {
    const errors = watchPageErrors(page);
    await page.goto("/lab/phantom_deeplink");

    await expect(page.locator('[data-test="deeplink-state"]')).toHaveAttribute("data-deeplink", "false");

    expect(await page.evaluate(() => typeof startPhantomDeepLink)).toBe("undefined");
    expect(await page.evaluate(() => typeof window.startPhantomDeepLink)).toBe("undefined");

    expect(errors).toEqual([]);
  });
});
