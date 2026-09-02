# frozen_string_literal: true

require_relative "view_render_support"
require "json"
require "open3"
require "tempfile"

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
    # THE ADDITIVE CONTRACT. The ONE host that renders this partial today — the
    # engine's living style guide — does not know the local exists.
    #
    # COUNTED, because this comment used to say "two hosts ... the engine's real
    # modal and its living style guide" and the second one does not exist. Every
    # render site of solana_studio/auth/wallet_credential across studio-engine,
    # mcritchie-studio and turf-monster, on accepted AND main, is a single line:
    # studio-engine's style/modals/_auth.html.erb:238, passing modal_store only.
    # "modals" is the store the engine's real modal HOST registers
    # (studio/modals/_host.html.erb) — a naming convention this partial honours,
    # not a second caller. The byte-identity argument leans on that inventory,
    # so the inventory is stated as measured rather than assumed.
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
    # PARENTHESISED, and the parentheses are not cosmetic — see the CONTROL tier
    # at the bottom of this file for what they buy and what it cost to learn.
    assert_equal "attested() && (openWalletHub())",
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

  def test_the_age_gate_leads_every_override
    # THE REASON on_click IS THE TAIL AND NOT THE WHOLE HANDLER. `attested()` is
    # template text no local can reach, so a host cannot drop the legal-age gate
    # by simply never calling it — a handler that did would look and behave
    # completely normal.
    #
    # WHAT THIS ASSERTION ACTUALLY PROVES, stated narrowly because the comment
    # that stood here did not. `start_with?` proves the gate LEADS the handler.
    # It does NOT prove the gate CONTROLS the tail, and the difference is a real
    # bypass rather than a quibble: `attested() && a() || b()` starts with this
    # exact prefix and still runs `b()` with the gate FALSE. That handler passed
    # this assertion for the whole life of the seam.
    #
    # Control is asserted below, in a JS engine, because it is a property of the
    # PARSE and no string comparison can see it.
    %w[openWalletHub() somethingElse()].each do |handler|
      assert button(render_credential(on_click: handler))["@click"].start_with?("attested() && "),
             "the age gate must lead the handler even when the tail is overridden"
    end
  end

  # --- the age gate CONTROLS the tail, not merely leads it --------------------
  #
  # WHY THIS TIER EXISTS ON TOP OF THE STRING ASSERTIONS ABOVE. Every assertion
  # so far compares text, and the defect this section pins is invisible to text:
  # the handler is ONE JavaScript expression, and whether the gate governs the
  # override or merely its first term is decided by OPERATOR PRECEDENCE at parse
  # time. `&&` binds tighter than `||`, `?:` and comma, so an override built on
  # any of those reparses and its tail runs with the gate FALSE. The rendered
  # string looks correct either way. Only an engine can tell them apart.
  #
  # MEASURED IN CHROMIUM against studio-engine's vendored Alpine 3.16.1, with
  # attested() returning false, on the handler as it was rendered BEFORE the
  # override was parenthesised:
  #
  #   saveCart() || openWalletHub()   -> openWalletHub() RAN
  #   wantsHub ? openHub() : save()   -> save() RAN
  #   saveCart(), openWalletHub()     -> openWalletHub() RAN
  #
  # Node stands in for the browser here for the same reason the guard suite uses
  # it: precedence is a language property, not a browser one, and a Rails suite
  # cannot own a browser. The browser measurement above is what licenses that
  # substitution, and it was re-run after the fix with all three blocked.

  # Every top-level operator that binds LOOSER than the gate's `&&`. These are
  # the complete set of shapes that reparse; a bare call cannot.
  BYPASS_SHAPES = {
    "||" => "saveCart() || openWalletHub()",
    "?:" => "wantsHub ? openWalletHub() : saveCart()",
    "," => "saveCart(), openWalletHub()"
  }.freeze

  def setup
    # FAILS rather than skips, matching test/network_guard_js_test.rb: a skipped
    # lane is lost coverage that reads as green, and bin/release-check rejects a
    # file that skips for exactly that reason.
    assert system("node --version > /dev/null 2>&1"),
           "node is required to evaluate the click handler (install node)"
  end

  # Runs `click` in a real JS engine and returns the tail members that executed,
  # with `attested()` returning `gate`.
  #
  # BUILT THE WAY ALPINE BUILDS IT: Alpine compiles a handler to
  # `with (scope) { result = <expression> }`, so the expression lands in a
  # right-hand side, UNPARENTHESISED, and this mirrors that.
  #
  # THE OBVIOUS REASON TO MIRROR IT IS NOT THE REAL ONE, and the difference was
  # measured rather than assumed. Wrapping the whole expression here does NOT
  # hide the bug: `(a && b || c)` groups exactly like `a && b || c`, so the outer
  # parentheses change nothing for any shape below — the mutation was run, and
  # all 14 tests stayed green. The reason to match Alpine is fidelity to the
  # engine whose parse is being asserted, not a guard this helper provides.
  def tail_that_ran(click, gate:)
    harness = <<~JS
      const RAN = [];
      const scope = {
        attested() { return #{gate}; },
        wantsHub: true,
        openWalletHub() { RAN.push("openWalletHub"); },
        saveCart() { RAN.push("saveCart"); },
        $store: { modals: { swap() { RAN.push("swap"); } } }
      };
      let __result;
      with (scope) { __result = #{click} }
      console.log(JSON.stringify(RAN));
    JS

    Tempfile.create(["click", ".js"]) do |f|
      f.write(harness)
      f.flush
      # SEPARATE STREAMS, for the reason network_guard_js_test.rb records: stdout
      # is JSON.parsed, so any node chatter folded in arrives as a parse error in
      # a test about the age gate.
      out, err, status = Open3.capture3("node", f.path)
      raise "node failed for #{click.inspect}: #{err}" unless status.success?

      JSON.parse(out.strip)
    end
  end

  def test_a_failed_age_gate_stops_an_override_whatever_its_top_level_operator
    BYPASS_SHAPES.each do |operator, override|
      click = button(render_credential(on_click: override))["@click"]

      assert_empty tail_that_ran(click, gate: false),
                   "attested() is false, so a top-level #{operator} override must run NOTHING; " \
                   "the handler was #{click}"
    end
  end

  def test_the_unparenthesised_handler_really_did_run_the_tail
    # THE CONTROL, and this file needs one more than most. Every "must not run"
    # assertion above is satisfied just as well by a harness that can no longer
    # run ANYTHING, so a green run proves the fix holds only once the harness is
    # shown able to report a tail that did execute. This reconstructs the pre-fix
    # spelling by hand and asserts the bypass is still reproducible.
    #
    # WHAT IT WAS MEASURED TO CATCH, rather than what it feels like it catches.
    # Two mutations were run against this file: making `tail_that_ran` always
    # return [] took THIS test and the gate-true one red while the bypass
    # assertions stayed green, and pinning `attested()` to a constant took two
    # red. A mutation that merely reworded the harness — wrapping its expression
    # in parentheses — was correctly ignored by all 14, because it changes no
    # grouping.
    BYPASS_SHAPES.each do |operator, override|
      unparenthesised = "attested() && #{override}"

      refute_empty tail_that_ran(unparenthesised, gate: false),
                   "the harness must be able to SEE the bug: #{unparenthesised} bypassed " \
                   "the gate in Chromium, so it must bypass it here too"
    end
  end

  def test_a_passing_age_gate_still_runs_the_whole_override
    # THE OTHER DIRECTION, without which the fix above is indistinguishable from
    # breaking the button. A wrap that made the tail unreachable would satisfy
    # every "must not run" assertion in this file perfectly.
    BYPASS_SHAPES.each do |operator, override|
      click = button(render_credential(on_click: override))["@click"]

      refute_empty tail_that_ran(click, gate: true),
                   "attested() is true, so a top-level #{operator} override must still run"
    end
  end

  def test_a_failed_age_gate_stops_the_default_handler_too
    # The default is a single call expression and binds tighter than the gate
    # already, which is WHY it is left unparenthesised and stays byte-identical.
    # Asserted anyway: that reasoning is the justification for the asymmetry in
    # the template, and an unasserted justification is how the asymmetry gets
    # "tidied up" later.
    assert_empty tail_that_ran(button(render_credential)["@click"], gate: false)
    refute_empty tail_that_ran(button(render_credential)["@click"], gate: true)
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
