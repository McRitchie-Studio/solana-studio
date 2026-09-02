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

// ── OPSEC-005: THE USER-ID BINDING ────────────────────────────────────────────
//
// The specs above drive LOGIN mode, where the statement is just the app's own
// sentence. LINK mode — connecting a wallet to an account that is ALREADY signed
// in — appends one line:
//
//     statement + '\nUser-ID: ' + currentUserId
//
// and that line is the entire mechanism tying a signature to an account. Nothing
// in any repo proved the client builds it. Checked, not assumed, before this file
// grew: turf-monster covers the SERVER's substring check
// (test/controllers/solana_sessions_controller_test.rb) and that the picker passes
// BOTH arguments (test/views/phantom_deeplink_adoption_test.rb); its browser spec
// names startPhantomDeepLink only in comments and never calls it in link mode; and
// the spec above asserts the login-mode NEGATIVE, which is the absence of this
// line rather than its shape. The construction itself was watched by nobody.
//
// WHY THAT IS OPSEC AND NOT COVERAGE BOOKKEEPING. Get the line wrong — wrong id,
// wrong separator, no line at all — and the user signs a statement that does not
// say what the server will later assume it said. It is the same failure shape as
// the encoder above: the wallet signs, the request posts, nothing throws, and the
// binding either silently fails to bind or binds to someone else.
//
// AND THE LINE HAS A SECOND READER. studio-engine's solana_sessions/phantom_callback
// RECONSTRUCTS the signed message from localStorage when Phantom returns without
// one, re-running `statementLine += '\nUser-ID: ' + storedUserId` over the id THIS
// program parked. So the id inside the signature and the id left behind for the
// callback have to be the same bytes, or the reconstruction signs a different
// message than the wallet did. That coupling is asserted below.
//
// WHY THE ASSERTION IS BYTES. A `toContain("User-ID:")` or a
// /User-ID:\s*\d+/ passes on a binding built with a CRLF, a non-breaking space, or
// any other separator the server's substring match would miss — the negative
// control in the first spec builds exactly those and shows both loose checks
// accepting them. Deleting B58_ALPHABET, the defect that actually shipped, left
// the "does it parse" spec green; only the spec that compared BYTES went red. This
// is the same lesson applied to the same partial one layer up.

// The binding's separator, spelled as the BYTES the server matches on rather than
// as a string literal. A literal is invisible to exactly the mutations that matter,
// because a wrong separator and a right one are the same shape on screen: a CRLF, a
// non-breaking space, a missing space. The trailing 0x20 is why this file spends so
// many words on ten bytes — it is a space, and every wrong version of it also looks
// like a space. turf-monster's server check is an include? of "User-ID: <id>"
// (test/controllers/solana_sessions_controller_test.rb), so that one byte is the
// difference between a bound signature and an unbound one.
//
//                       \n    U     s     e     r     -     I     D     :   space
const BINDING_BYTES = [0x0a, 0x55, 0x73, 0x65, 0x72, 0x2d, 0x49, 0x44, 0x3a, 0x20];

// A Rails id, as an integer, because that is what a caller passes — the partial
// interpolates it into a string and String()s it into localStorage, and those two
// coercions are separate code paths that can disagree. 4242 is deliberately a
// value whose hex spelling (1092) differs from its decimal one, so a coercion
// that changed base is visible rather than plausible.
const USER_ID = 4242;

const textBytes = (str) => Array.from(new TextEncoder().encode(str));

// The lab, in the state that renders the partial, PROVEN to be that state. Without
// the attribute check a redirect or a 404 body would let every assertion below
// describe some other document — the failure mode where a probe "passes" while
// sitting on a page that was never under test.
async function openLab(page) {
  await page.goto("/lab/phantom_deeplink?deeplink=1");
  await expect(page.locator('[data-test="deeplink-state"]')).toHaveAttribute("data-deeplink", "true");
}

// One full hand-off: call the real entry point, catch the navigation, decode what
// the user would have signed. Returns the statement as BYTES, because that is the
// only form in which the questions below have a definite answer.
async function driveDeepLink(page, linkMode, userId) {
  const navigation = page.waitForRequest(
    (r) => r.url().startsWith("https://phantom.app/ul/v1/signIn"),
    { timeout: 15000 },
  );
  await page.evaluate(([mode, id]) => window.startPhantomDeepLink(mode, id), [linkMode, userId]);
  const url = new URL((await navigation).url());

  // The request being ISSUED and the browser actually GOING there are different
  // events; waiting for the second also makes the return trip below deterministic
  // rather than a race against a navigation still committing.
  await page.waitForURL(/^https:\/\/phantom\.app\/ul\/v1\/signIn/);

  const siws = JSON.parse(new TextDecoder().decode(decodeBase58(url.searchParams.get("payload"))));
  return { siws, statementBytes: textBytes(siws.statement) };
}

test.describe("phantom deep link · the OPSEC-005 user binding", () => {
  test("link mode appends the binding to the statement, byte for byte", async ({ page }) => {
    // THE INSTRUMENT CHECK, as the encoder spec does it: the hand-written byte
    // list and the separator it claims to spell, cross-checked against each other
    // before either is used to judge the partial. Both live in this file, so
    // neither can be moved by a defect in the thing under test.
    expect(new TextDecoder().decode(Uint8Array.from(BINDING_BYTES))).toBe("\nUser-ID: ");

    const errors = watchPageErrors(page);
    await stubTheFlow(page);

    // ── RUN 1: login mode, which establishes the BASELINE ─────────────────────
    //
    // Measured, not hardcoded. The base statement comes from Studio.app_name
    // through Studio.wallet_sign_in_statement and every consumer sets it to
    // something different, so a literal here would be asserting turf-monster's
    // configuration rather than this gem's behaviour. Driving the same program on
    // the same page with one argument changed isolates the binding as the ONLY
    // thing that can account for a difference between the two runs.
    await openLab(page);
    const login = await driveDeepLink(page, false, null);

    // ── RUN 2: link mode, one argument different ──────────────────────────────
    await openLab(page);
    const link = await driveDeepLink(page, true, USER_ID);

    // 1. THE BASE STATEMENT SURVIVES UNTOUCHED. The binding is an APPEND; a
    //    version that prefixed it, re-cased the sentence, or rebuilt the statement
    //    around the id would still contain "User-ID: 4242" and still satisfy every
    //    loose check, and would fail here.
    expect(link.statementBytes.slice(0, login.statementBytes.length)).toEqual(login.statementBytes);

    // 2. THE TAIL IS EXACTLY THE BINDING AND NOTHING ELSE. Composed from the two
    //    independently-checked halves — the separator bytes above and the id this
    //    spec passed in — so a wrong separator and a wrong id are separately
    //    visible in the failure rather than collapsing into "the tail differs".
    const tail = link.statementBytes.slice(login.statementBytes.length);
    expect(tail).toEqual([...BINDING_BYTES, ...textBytes(String(USER_ID))]);

    // 3. NEGATIVE CONTROL — the point of the whole file.
    //
    //    Three wrong bindings, each one a reader would have to look twice to spot.
    //    They are built from ESCAPES rather than typed, because the first draft of
    //    this block typed the non-breaking space as an ordinary one and produced a
    //    "wrong" binding byte-identical to the right one — the exact invisibility
    //    this spec exists to remove, reproduced while writing the spec for it.
    //
    //    The server's OPSEC-005 check is a SUBSTRING match on "User-ID: <id>", so
    //    every one of these binds nothing while looking correct in a log, in a
    //    debugger, and in a code review.
    const wrongBindings = {
      "CRLF separator": "\r\nUser-ID: " + USER_ID,
      "non-breaking space after the colon": "\nUser-ID:\u00a0" + USER_ID,
      "no space after the colon": "\nUser-ID:" + USER_ID,
    };

    for (const [label, wrong] of Object.entries(wrongBindings)) {
      // THE TWO CHECKS A REVIEWER REACHES FOR FIRST, and both ACCEPT all three
      // wrong bindings — asserted rather than claimed, so the argument for the
      // byte comparison below is demonstrated in the file that makes it.
      expect(wrong, `${label}: a substring check accepts it, which is the problem`)
        .toContain("User-ID:");
      expect(wrong, `${label}: the tighter regex accepts it too`).toMatch(/\sUser-ID:\s*\d+/);

      // THE COMPARISON THIS SPEC ACTUALLY MAKES, and it rejects them.
      expect(textBytes(wrong), `${label}: the byte comparison must reject it`).not.toEqual(tail);
    }

    //    And the control that keeps the loop above meaningful: the comparison
    //    ACCEPTS the correct binding. An assertion that rejected everything would
    //    satisfy every line in the loop while proving nothing.
    expect(textBytes("\nUser-ID: " + USER_ID)).toEqual(tail);

    // 4. THE ID PARKED FOR THE CALLBACK IS THE ID INSIDE THE SIGNATURE.
    //
    //    studio-engine's phantom_callback rebuilds the signed message from
    //    localStorage when Phantom returns without one. If these two ever disagree
    //    — a base change, a truncation, an object stringified one way here and
    //    another there — the reconstruction posts a message the wallet never
    //    signed, and verification fails with nothing in the log to say why.
    //
    //    Read from the LAB's origin: the call above navigated to the phantom.app
    //    stub and localStorage is per-origin, so reading it there would ask the
    //    wrong document and get null for everything.
    await openLab(page);
    const parked = await page.evaluate(() => ({
      userId: localStorage.getItem("phantom_dl_user_id"),
      linkMode: localStorage.getItem("phantom_dl_link_mode"),
    }));

    expect(textBytes(parked.userId)).toEqual(tail.slice(BINDING_BYTES.length));
    // The callback gates its reconstruction on BOTH keys, so link mode has to
    // survive the handoff too — an id parked under link_mode "false" is an id the
    // callback will never read.
    expect(parked.linkMode).toBe("true");

    expect(errors).toEqual([]);
  });

  // THE OTHER HALF OF THE GUARD, and a branch nothing else drives. The partial
  // gates on `linkMode && currentUserId`; studio-engine's callback gates its
  // reconstruction on the same conjunction over the values THIS program parked. A
  // version that gated on linkMode ALONE would sign "\nUser-ID: null" while the
  // callback, finding no parked id, rebuilt the message WITHOUT that line — the two
  // halves disagreeing about what was signed, which is the failure the binding
  // exists to prevent showing up as the binding itself. The server's check is
  // `message.to_s.include?("User-ID: #{expected_user_id}")` (studio-engine
  // app/controllers/concerns/solana/session_auth.rb:33), and the literal "null"
  // satisfies it for no real user, so the round trip ends in a refused wallet whose
  // log line says only that the binding was missing.
  //
  // Asserted as a byte IDENTITY against a login-mode run rather than as an absence,
  // because "does not contain User-ID:" is the weak form: it cannot see a binding
  // built with a different separator, which is precisely the class this file exists
  // to catch.
  test("link mode without a user id signs the same bytes as a plain login", async ({ page }) => {
    const errors = watchPageErrors(page);
    await stubTheFlow(page);

    await openLab(page);
    const login = await driveDeepLink(page, false, null);

    // A STALE BINDING from an earlier link attempt, seeded immediately before the
    // run that must clear it. localStorage survives the round trip to Phantom by
    // design — that is how the callback gets its state — so an id left behind by a
    // previous attempt is a real page state, and one the callback would replay into
    // a message this user never signed.
    await openLab(page);
    await page.evaluate(() => localStorage.setItem("phantom_dl_user_id", "999999"));
    const linkNoId = await driveDeepLink(page, true, null);

    expect(linkNoId.statementBytes).toEqual(login.statementBytes);

    await openLab(page);
    expect(await page.evaluate(() => localStorage.getItem("phantom_dl_user_id"))).toBeNull();

    expect(errors).toEqual([]);
  });
});
