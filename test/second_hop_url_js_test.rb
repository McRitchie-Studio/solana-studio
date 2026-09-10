require_relative "test_helper"
require "json"
require "tempfile"
require "open3"

# THE SECOND HOP'S URL — the thing no test in this repo had ever looked at.
#
# WHY THIS FILE EXISTS. On 2026-09-09 a real iPhone drove this transport against
# QA. Hop one completed correctly: Phantom returned a genuine
# phantom_encryption_public_key, nonce and data. Hop two opened Phantom to its
# HOME SCREEN and the entry was lost after the user had already approved it.
#
# The cause was that `redirectLink` never survived the page death — beginConnect
# journalled the dapp keypair and the intent but not the return address, so the
# signing hop built its URL with redirect_link undefined. wallet_transport's
# query() SKIPS undefined values, so the parameter simply vanished and the
# request looked well formed on the way out.
#
# EVERY EXISTING TEST PASSED. They assert the FIRST hop's URL, or they assert the
# decrypted result of a hop they constructed by hand. Not one inspected what a
# wallet would actually RECEIVE on the second hop. That is the gap this closes,
# and it is why the assertions below read the URL rather than the outcome.
class SecondHopUrlJsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  NACL = File.join(ROOT, "node_modules", "tweetnacl")

  def self.node? = (@node ||= system("node --version > /dev/null 2>&1"))

  def setup
    assert self.class.node?, "node is required (install node)"
    assert Dir.exist?(NACL), "tweetnacl is required — run `npm ci` in the gem root"
  end

  def gem_js(*names)
    names.map { |n| File.read(File.join(ROOT, "app/assets/javascripts/solana_studio/#{n}.js")) }.join("\n")
  end

  # Drives connect -> resume -> second hop for `wallet`, with the journal
  # round-tripped through JSON between them. Returns the SECOND hop's URL, parsed.
  def second_hop(wallet, redirect_link: "https://qa.turfmonster.media/auth/phantom/callback")
    script = <<~JS
      global.window = global;
      global.nacl = require(#{NACL.to_json});
      var MEM = {};
      global.localStorage = {
        getItem: function (k) { return k in MEM ? MEM[k] : null; },
        setItem: function (k, v) { MEM[k] = String(v); },
        removeItem: function (k) { delete MEM[k]; },
        get length() { return Object.keys(MEM).length; },
        key: function (i) { return Object.keys(MEM)[i]; }
      };
      console.log = function () {};
      #{gem_js('wallet_transport', 'redirect_provider', 'wallet_journal', 'wallet_ops')}

      var S = window.SolanaStudio;
      S.walletOps.define('probe', {
        prepare: function () { return Promise.resolve({ transaction: 'TXB58' }); },
        complete: function () { return Promise.resolve('done'); }
      });

      var urls = [];
      var provider = S.redirectProvider.forWallet(#{wallet.to_json});

      (async function () {
        // ---- the page that starts the trip ----
        await S.walletOps.run('probe', {}, {
          provider: provider,
          appUrl: 'https://qa.turfmonster.media',
          redirectLink: #{redirect_link.to_json},
          cluster: 'devnet',
          navigate: function (u) { urls.push(u); }
        });

        // ---- the wallet answers the connect hop ----
        var walletPair = nacl.box.keyPair();
        var dappPub = new URL(urls[0]).searchParams.get('dapp_encryption_public_key');
        var shared = nacl.box.before(S.walletTransport.base58.decode(dappPub), walletPair.secretKey);
        var n = nacl.randomBytes(24);
        var body = new TextEncoder().encode(JSON.stringify({ public_key: 'PK', session: 'SESS' }));

        // THE PAGE DIES HERE. The callback document calls resume with NO
        // redirectLink — it has no caller and no way to know one. Everything the
        // second hop needs must already be in the journal.
        await S.walletOps.resume({
          phantom_encryption_public_key: S.walletTransport.base58.encode(walletPair.publicKey),
          solflare_encryption_public_key: S.walletTransport.base58.encode(walletPair.publicKey),
          wallet_encryption_public_key: S.walletTransport.base58.encode(walletPair.publicKey),
          nonce: S.walletTransport.base58.encode(n),
          data: S.walletTransport.base58.encode(nacl.box.after(body, n, shared))
        }, { navigate: function (u) { urls.push(u); } });

        process.stdout.write(JSON.stringify({ urls: urls }));
      })().catch(function (e) { process.stdout.write(JSON.stringify({ error: e.message })); });
    JS

    Tempfile.create(["second_hop", ".js"]) do |f|
      f.write(script)
      f.flush
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      JSON.parse(out)
    end
  end

  # --- the regression itself ------------------------------------------------

  def test_the_second_hop_carries_a_return_address
    # THE BUG, asserted directly. Without redirect_link the wallet has nowhere to
    # send the signature, so it opens to its home screen and the entry is lost
    # with the user believing they approved it.
    result = second_hop("phantom")
    refute result["error"], "trip errored: #{result['error']}"
    assert_equal 2, result["urls"].size, "a cold session is connect then sign"

    hop = URI.parse(result["urls"][1])
    params = URI.decode_www_form(hop.query).to_h

    assert_equal "https://qa.turfmonster.media/auth/phantom/callback", params["redirect_link"],
                 "the second hop must return to the SAME callback the first one did"
  end

  def test_the_second_hop_carries_everything_a_wallet_needs
    # redirect_link was the one that bit us, but the class is "a field the resume
    # needed was not there". Assert the whole required set, so the next omission
    # fails here rather than on someone's phone.
    result = second_hop("phantom")
    params = URI.decode_www_form(URI.parse(result["urls"][1]).query).to_h

    %w[dapp_encryption_public_key nonce payload redirect_link].each do |field|
      refute_nil params[field], "the second hop is missing #{field}"
      refute_empty params[field].to_s, "the second hop sent an empty #{field}"
    end
  end

  def test_every_wallet_carries_it_not_just_phantom
    # One code path serves three wallets, so a per-wallet regression is only real
    # if it is asserted per wallet.
    %w[phantom solflare backpack].each do |wallet|
      result = second_hop(wallet)
      refute result["error"], "#{wallet} errored: #{result['error']}"
      params = URI.decode_www_form(URI.parse(result["urls"][1]).query).to_h
      refute_nil params["redirect_link"], "#{wallet}'s second hop lost the return address"
    end
  end

  def test_an_incomplete_request_is_refused_rather_than_built
    # THE STRUCTURAL HALF. Even if a future change loses the value again, the URL
    # builder must refuse instead of emitting a request a wallet cannot answer —
    # query() skipping undefined is what made the original failure invisible.
    script = <<~JS
      global.window = global;
      #{gem_js('wallet_transport')}
      var t = window.SolanaStudio.walletTransport;
      var out = {};
      try { t.url.method('phantom', 'signTransaction', { dappPublicKey: 'K', nonce: 'N', payload: 'P' }); out.built = true; }
      catch (e) { out.refused = e.message; }
      process.stdout.write(JSON.stringify(out));
    JS
    Tempfile.create(["guard", ".js"]) do |f|
      f.write(script); f.flush
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, err
      result = JSON.parse(out)
      refute result["built"], "a request with no return address must never be built"
      assert_match(/redirect_link/, result["refused"])
      assert_match(/nowhere to return/i, result["refused"])
    end
  end
end
