# frozen_string_literal: true

require_relative "view_render_support"
require "open3"
require "json"
require "cgi"

# [unit] The picker's mobile handoff rows, EVALUATED rather than string-matched.
#
# THE BUG THIS CLOSES. Until 2026-09-07 the picker told readers "there is no deep
# link for" Solflare and Backpack, and handed a phone their DESKTOP EXTENSION
# download page — a dead end with no error, for two wallets that each ship a full
# deeplink protocol. The claim was false; the consequence was live.
#
# WHY THESE ASSERTIONS RUN THE COMPONENT. The sibling test in this directory
# pins the picker's source strings, which is the right tier for "did the hook
# reach the attribute". It cannot answer whether the LIST those hooks compute is
# correct — and a row list is exactly where an honesty rule lives: a row must be
# painted only when tapping it does something. So this renders the partial, lifts
# the x-data out of the attribute, and calls the getters in Node.
class WalletPickerMobileHandoffTest < Minitest::Test
  include ViewRenderSupport

  PARTIAL = "solana_studio/modals/wallet_connect"

  IPHONE = "iPhone"
  DESKTOP = "desktop"

  # Evaluate the RENDERED component with a controllable environment.
  #
  # `registry:` false stands in for a consumer that does not load
  # redirect_provider.js — the absent-capability case, which must not default to
  # the permissive branch.
  # `registry:` true | false | :partial
  #   false   — the consumer loads no redirect_provider.js at all
  #   :partial — it loads an OLDER one that predates all(), which is what a gem
  #              floor mismatch actually looks like: the namespace is there, the
  #              method is not
  def evaluate(device:, injected: [], registry: true, deep_link: true)
    xd = x_data(render_picker)
    refute_empty xd, "could not lift the x-data attribute out of the rendered picker"

    script = <<~JS
      global.window = global;
      #{deep_link ? "global.startPhantomDeepLink = function() {};" : ""}
      #{registry_js(registry)}
      global.walletProvider = { isMobile: function() { return #{device == IPHONE}; } };

      var component = #{CGI.unescapeHTML(xd)};
      component.wallets = #{injected.map { |n| { name: n } }.to_json};

      console.log(JSON.stringify({
        handoffs: component.mobileHandoffs.map(function(w) { return w.name; }),
        installs: component.missingInstalls.map(function(i) { return i.name; }),
        showPhantomDeepLink: component.showPhantomDeepLink
      }));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  # A stand-in for solana_studio/redirect_provider.js, shaped from its PUBLIC
  # surface (all/forWallet/can/key/name/browseUrl) rather than from what makes
  # this test pass. The real file is driven by its own suites in this repo; what
  # is under test here is what the PICKER does with the answers.
  def registry_js(registry)
    case registry
    when false then ""
    when :partial then "global.SolanaStudio = { redirectProvider: { forWallet: function() { return null; } } };"
    else redirect_provider_stub
    end
  end

  def redirect_provider_stub
    <<~JS
      global.SolanaStudio = { redirectProvider: {
        all: function() {
          return ['phantom', 'solflare', 'backpack'].map(function(k) {
            return {
              key: k,
              name: k.charAt(0).toUpperCase() + k.slice(1),
              can: function(m) { return m === 'browse'; },
              browseUrl: function(t, r) { return 'https://' + k + '.example/ul/browse/' + encodeURIComponent(t) + '?ref=' + r; }
            };
          });
        }
      } };
    JS
  end

  def test_a_phone_is_offered_the_two_wallets_that_had_no_path_at_all
    result = evaluate(device: IPHONE)

    # Phantom is absent from the handoffs BY DESIGN: its own deep-link row is a
    # full sign-in, and offering both would race two Phantom rows.
    assert_equal %w[Solflare Backpack], result["handoffs"]
    assert result["showPhantomDeepLink"], "Phantom keeps its richer row"
  end

  def test_a_wallet_with_a_working_handoff_is_not_also_offered_a_download_page
    result = evaluate(device: IPHONE)

    # THE ACTUAL DEFECT: solflare.com/download shown to a phone. A wallet cannot
    # hold both rows — one of them is always a lie about what will happen.
    refute_includes result["installs"], "Solflare"
    refute_includes result["installs"], "Backpack"
    refute_includes result["installs"], "Phantom"
  end

  def test_a_desktop_is_offered_no_handoffs_and_keeps_its_install_rows
    result = evaluate(device: DESKTOP)

    assert_empty result["handoffs"], "there is no wallet app to open on a desktop"
    assert_equal %w[Phantom Solflare Backpack], result["installs"],
                 "the install page is the correct advice for a browser that can host an extension"
  end

  def test_an_injected_wallet_gets_no_handoff_row
    # Inside Solflare's own in-app browser the detected row above already offers
    # a working connect; a handoff would offer to leave Solflare to open Solflare.
    result = evaluate(device: IPHONE, injected: ["Solflare"])

    refute_includes result["handoffs"], "Solflare"
    assert_includes result["handoffs"], "Backpack"
  end

  def test_a_consumer_without_the_registry_paints_no_handoff_rows
    # THE ABSENT-CAPABILITY RULE, which this picker learned the hard way once
    # already: without it, adopting the picker replaced a dead-end install row
    # with a dead BUTTON. A consumer that does not load redirect_provider.js must
    # fall back to install rows, not to rows that do nothing.
    result = evaluate(device: IPHONE, registry: false)

    assert_empty result["handoffs"]
    assert_includes result["installs"], "Solflare",
                    "with no registry the download page is again the only path there is"
  end

  def test_an_older_registry_without_all_is_treated_as_absent
    # THE GEM FLOOR CASE, and the one a `!rp` check alone would miss: the
    # namespace is present because SOME version of redirect_provider.js loaded,
    # but it predates all(). Calling it would throw inside a getter Alpine
    # evaluates on every open, which takes the whole picker down rather than
    # degrading one row. Found by mutation testing — removing the typeof guard
    # broke nothing until this test existed.
    result = evaluate(device: IPHONE, registry: :partial)

    assert_empty result["handoffs"]
    assert_includes result["installs"], "Solflare"
  end

  def test_phantom_falls_back_to_a_handoff_when_it_has_no_deep_link
    # A consumer that renders the registry but NOT solana_studio/phantom_deeplink.
    # Phantom should still get a working row rather than a download page.
    result = evaluate(device: IPHONE, deep_link: false)

    assert_includes result["handoffs"], "Phantom"
    refute result["showPhantomDeepLink"]
    refute_includes result["installs"], "Phantom"
  end

  private

  def render_picker(**locals)
    view.render(partial: PARTIAL, locals: locals)
  end

  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class="relative"/m, 1].to_s
  end
end
