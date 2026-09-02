# frozen_string_literal: true

require_relative "view_render_support"

# [unit] solana_studio/auth/_wallet_credential — the contributed sign-in button,
# asserted at the RENDER tier.
#
# WHY THIS FILE EXISTS ALONGSIDE test/auth_credential_test.rb. That suite reads
# the SOURCE with ERB comments stripped, and there is a whole class of contract
# it structurally cannot see. The click handler is now written
# `attested() && <%= raw on_click %>`, so the string a host actually depends on
# — `attested() && $store.modals.swap('wallet-connect', ...)` — appears ZERO
# times in the file. The default, the override, and the escaping decision all
# exist only after ERB runs. A source grep is green on a partial whose default
# never reaches the attribute at all.
#
# THE SEAM THESE PIN. The button had ONE hardcoded click, and Turf Monster could
# not adopt it: its board stages a lineup in localStorage and must WRITE that
# before the wallet picker's unconditional navigation leaves the page. Adopting
# verbatim loses a staged lineup on wallet sign-in. `on_click` is the seam, and
# every assertion below exists to keep it additive.
class AuthWalletCredentialTest < Minitest::Test
  include ViewRenderSupport

  PARTIAL = "solana_studio/auth/wallet_credential"

  # The exact handler every host got before the seam existed. Written out in
  # full, ON PURPOSE: this constant IS the byte-identity contract. The change
  # that introduced `on_click` was required to leave a host that passes no
  # locals with output identical to what it had, and the only honest way to
  # assert that is to compare against the literal previous bytes rather than
  # against something recomputed from the same template that could drift with it.
  DEFAULT_CLICK =
    "attested() && $store.modals.swap('wallet-connect', { backTo: 'auth', ageAttested: true })"

  def render_credential(locals = {})
    view.render(partial: PARTIAL, locals: { modal_store: "modals" }.merge(locals))
  end

  def button(html)
    Nokogiri::HTML5.fragment(html).at_css("button")
  end

  # --- the default, unchanged ------------------------------------------------

  def test_a_host_that_passes_no_on_click_gets_the_original_handler
    # THE ADDITIVE CONTRACT. Two hosts already render this partial — the engine's
    # real modal and its living style guide — and neither knows the local exists.
    assert_equal DEFAULT_CLICK, button(render_credential)["@click"]
  end

  def test_the_default_handler_follows_the_store_name
    # The style guide mounts a page-scoped host and passes "dsModals". The
    # default is built from modal_store, so it must track it; a default that
    # hardcoded "modals" would give the guide a button that silently does
    # nothing, which is the exact failure modal_store has no default to avoid.
    assert_equal DEFAULT_CLICK.sub("$store.modals", "$store.dsModals"),
                 button(render_credential(modal_store: "dsModals"))["@click"]
  end

  # --- the override ----------------------------------------------------------

  def test_on_click_replaces_the_default_action
    assert_equal "attested() && openWalletHub()",
                 button(render_credential(on_click: "openWalletHub()"))["@click"]
  end

  def test_an_override_leaves_no_trace_of_the_default
    # A HALF-SWAPPED HOOK is the failure that actually ships: the button still
    # renders and only misbehaves in a browser it was not mounted in. If any of
    # the default's swap survived alongside the override, turf would save its
    # cart AND navigate straight past it.
    click = button(render_credential(on_click: "openWalletHub()"))["@click"]

    %w[wallet-connect backTo ageAttested $store].each do |leftover|
      refute_includes click, leftover,
                      "an overridden handler must not keep #{leftover} from the default"
    end
  end

  def test_the_age_gate_survives_an_override
    # THE REASON on_click IS THE TAIL AND NOT THE WHOLE HANDLER. `attested()` is
    # template text no local can reach, so a host cannot drop the legal-age gate
    # — not even by accident, and a handler that simply never called it would
    # look and behave completely normal.
    %w[openWalletHub() somethingElse()].each do |handler|
      assert button(render_credential(on_click: handler))["@click"].start_with?("attested() && "),
             "the age gate must lead the handler even when the tail is overridden"
    end
  end

  # --- escaping --------------------------------------------------------------

  def test_the_handler_reaches_the_page_unescaped
    # READ FROM THE RAW HTML, NEVER THE PARSED ATTRIBUTE. Nokogiri decodes
    # entities, so `&amp;&amp;` and `&&` are the SAME string once parsed and this
    # assertion would pass on the bug it exists to catch. An escaped handler
    # still works — the HTML parser decodes it before Alpine reads it — so the
    # page looks correct and only the shipped bytes are wrong, which is why
    # nothing else here would ever notice.
    html = render_credential

    assert_includes html, "attested() && $store",
                    "the handler must be emitted raw"
    refute_includes html, "&amp;&amp;",
                    "an escaped handler means the raw marker was dropped"
    refute_includes html, "&#39;wallet-connect&#39;"
  end

  def test_the_default_handler_carries_no_double_quote
    # A double quote inside the double-quoted attribute closes it early and
    # Alpine mounts a SILENT NO-OP: the markup still renders, so every other
    # assertion here still passes while the button is dead on the page. Hosts
    # are told to keep their own overrides single-quoted for the same reason;
    # this pins the half the gem controls.
    click = button(render_credential)["@click"]

    refute_empty click
    refute_includes click, '"'
  end

  # --- the visibility gate ---------------------------------------------------

  def test_the_gate_still_consults_the_shared_toggle
    # methodOn('wallet') is the engine's shared per-method switch and the style
    # guide's specimen toggles drive it. Tolerating its ABSENCE must not stop it
    # being CONSULTED where it exists, or the guide gets a button it cannot turn
    # off. Verified in Chromium against the vendored Alpine 3.16.1: with the
    # toggle defined, the button follows it in both directions.
    assert_includes button(render_credential)["x-show"], "methodOn('wallet')"
  end

  def test_the_gate_tolerates_a_host_that_never_defined_the_toggle
    # THE DEFECT THIS PINS, measured in Chromium against the vendored Alpine
    # 3.16.1 before the guard existed: in a host with no methodOn, the bare call
    # throws `methodOn is not defined`, Alpine grades the throw as FALSY, and the
    # button resolves to display:none. No error a user can see, no missing
    # asset, nothing in the page to debug — the credential simply is not there.
    # Turf Monster is that host, and this is what blocked its adoption.
    #
    # The fallback is TRUE, not false. Bundling the gem has already answered
    # "is wallet implemented"; a host with no toggle has expressed no opinion
    # about showing it, and defaulting to false rebuilds the same invisible
    # button from the other side.
    assert_equal "typeof methodOn === 'function' ? methodOn('wallet') : true",
                 button(render_credential)["x-show"]
  end

  def test_the_gate_stays_in_alpine_and_never_moves_into_ruby
    # THE SPLIT #258 SETTLED: Ruby answers "is this credential IMPLEMENTED" by
    # whether the partial resolves at all; Alpine answers "should it SHOW".
    # Folding the visibility into Ruby collapses that and brings back the
    # floating-divider bug — the modal draws a separator for a credential that
    # then hides itself. So the button must render REGARDLESS of any toggle, and
    # x-show must be the only thing deciding.
    refute_nil button(render_credential(on_click: "openWalletHub()")),
               "the button must always render; visibility belongs to x-show alone"
  end
end
