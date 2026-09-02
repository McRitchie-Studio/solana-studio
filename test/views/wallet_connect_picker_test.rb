# frozen_string_literal: true

require_relative "view_render_support"

# [unit] solana_studio/modals/_wallet_connect — the Connect Wallet picker,
# asserted at the RENDER tier.
#
# Every assertion here exists because the thing it pins broke while the partial
# was being written, and in each case the page still RENDERED. That is the
# hazard of an Alpine component assembled through ERB: a picker with no hooks,
# and a picker whose hooks are HTML entities, both look fine on screen and both
# pass any assertion made against the source file.
class WalletConnectPickerTest < Minitest::Test
  include ViewRenderSupport

  PARTIAL = "solana_studio/modals/wallet_connect"

  # --- the extra_data seam ---------------------------------------------------

  def test_extra_data_reaches_the_x_data
    # THE BUG THIS PINS: the first draft passed extra_data through a heredoc
    # written inline in the render tag. An ERB tag closes at its FIRST close
    # marker, so the heredoc body became template TEXT, extra_data arrived
    # empty, and the picker rendered perfectly — minus every hook. Nothing
    # raised.
    #
    # Asserted on the x-data ATTRIBUTE, not on the document. This partial's own
    # doc comment names several hooks, so a document-wide check for a hook name
    # is green whether or not the hook ever reached the component.
    assert_includes x_data(render_picker(extra_data: "probeHook() { return 42; }")),
                    "probeHook() { return 42; }"
  end

  def test_extra_data_is_appended_after_the_built_ins_not_replacing_them
    xd = x_data(render_picker(extra_data: "probeHook() { return 42; }"))

    assert_includes xd, "probeHook()"
    %w[pick( refresh( deepLink( brandIcon( missingInstalls showPhantomDeepLink].each do |built_in|
      assert_includes xd, built_in, "the built-in #{built_in} must survive an extra_data merge"
    end
  end

  def test_no_extra_data_leaves_a_syntactically_clean_x_data
    # The fragment is built as `extra_data.present? ? (",\n       " + extra_data)
    # : ""`. Drop the ternary and an absent extra_data leaves the separator
    # behind — a trailing comma before the closing brace, which is a SyntaxError
    # in the Alpine expression and mounts the component as a silent no-op.
    xd = x_data(render_picker)

    refute_includes xd, ",\n       \n",
                    "an empty extra_data must not leave the separator behind as a dangling comma"
    # The same defect, pinned structurally as well, so a re-indent of the
    # partial cannot quietly retire the exact-whitespace check above.
    refute_match(/,\s*\}\s*\z/, xd, "the x-data must not end on a dangling comma")
    assert_includes xd, "back() {", "sanity: the built-ins must still be present to have a tail"
  end

  def test_extra_data_is_not_html_escaped
    # THE BUG THIS PINS: marking extra_data html_safe is NOT enough. Interpolate
    # a SafeBuffer into a plain string literal and the result is a plain String
    # — the safety is lost and every quote becomes an entity. That still PARSES,
    # because a browser decodes entities inside an attribute, so the page WORKS
    # and only the source reads wrong. No assertion on rendered markup catches
    # it; only reading the attribute's bytes does.
    xd = x_data(render_picker(extra_data: "onBack() { Alpine.store('dsModals').close(); }"))

    assert_includes xd, "Alpine.store('dsModals').close();"
    refute_includes xd, "&#39;", "the developer-authored fragment must not be entity-escaped"
  end

  # --- the store and connect_fn locals ---------------------------------------

  def test_defaults_target_the_shared_host_and_the_house_connect_function
    # THE STRINGS A CONSUMER DEPENDS ON APPEAR NOWHERE IN THE SOURCE. The seams
    # are written `$store.<%= store %>` and `window.<%= connect_fn %>(name,
    # opts)`, so these two literals exist only after ERB runs. This is precisely
    # the contract a source-level suite cannot assert.
    html = render_picker

    assert_includes html, "$store.modals.current()"
    assert_includes html, "window.solanaConnectAndVerify(name, opts)"
  end

  def test_store_local_rewires_every_store_reference
    # A HALF-SWAPPED STORE is the failure worth catching: the card mounts, reads
    # a host it was never mounted in, and shows an empty wallet list forever.
    # So the refute matters more than the asserts — it is what proves no
    # default-store reference was left behind.
    html = render_picker(store: "dsModals")

    assert_includes html, "$store.dsModals.current()"
    assert_includes html, "Alpine.store('dsModals').close()"
    refute_includes html, "$store.modals.", "no default-store reference may survive an override"
  end

  def test_connect_fn_local_rewires_the_connect_call
    html = render_picker(connect_fn: "dsWalletConnectDemo")

    assert_includes html, "window.dsWalletConnectDemo(name, opts)"
    refute_includes html, "window.solanaConnectAndVerify(",
                     "a half-swapped connect function leaves the picker calling a global the host never defined"
  end

  # --- structure -------------------------------------------------------------

  def test_single_root_element
    # The host mounts this inside a <template x-if>, and Alpine requires exactly
    # one root — a second top-level node is dropped silently.
    html = render_picker.strip

    assert_equal 1, element_children_count(html)
    # ...and the counter can actually SEE a second root. Without this control
    # the assertion above passed on a two-root document, because the scanner it
    # replaced misread the wallet row's void <img> and answered 1 for anything.
    assert_equal 2, element_children_count("#{html}\n<div>second root</div>")
  end

  def test_the_brand_sprite_definition_rides_inside_the_root
    # A sibling of the root is DROPPED by the host's template clone, and the
    # wallet rows then reference symbol ids that nothing ever painted.
    #
    # Asserted on the symbol DEFINITION, never on the bare id. "se-wallet-phantom"
    # appears twice in the rendered card — once defining the symbol (from the
    # engine's blocks/_wallet_brand_sprite, which this partial renders inside its
    # root) and once in the deep-link row's <use href>. The <use> is inside the
    # root wherever the sprite goes, so an id-substring check is satisfied by the
    # reference alone and stays green with the sprite moved out entirely. Proved
    # by mutation upstream: that form passed with the sprite relocated past the
    # root's close.
    assert_includes root_inner_html(render_picker), %(<symbol id="se-wallet-phantom")
  end

  # --- the named slot --------------------------------------------------------

  def test_the_named_slot_renders_inside_the_root
    html = render_picker(slot: "studio/modals/shared/age_attestation")

    # It must sit INSIDE the component root or it cannot see the x-data scope
    # extra_data contributes to — which is the entire point of the slot.
    assert_includes root_inner_html(html), "data-age-attestation"
  end

  def test_the_slot_takes_its_own_locals
    html = render_picker(slot: "studio/modals/shared/age_attestation",
                         slot_locals: { x_model: "probeModel" })

    assert_includes root_inner_html(html), %(x-model="probeModel")
  end

  def test_no_slot_renders_nothing_in_its_place
    refute_includes render_picker, "data-age-attestation"
  end

  # --- the slot must NOT be a block (the leak this partial shipped once) ------

  def test_rendering_without_a_slot_through_a_layout_leaks_nothing
    # THE BLOCKER THIS PINS, found in review. The first version took the slot as
    # a BLOCK and guarded it with `yield if block_given?`. `block_given?` is
    # ALWAYS TRUE inside a compiled Rails partial — PartialRenderer hands the
    # template a block either way — so with no caller block the yield fell
    # through to view_flow[:layout] and printed THE ENTIRE CAPTURED PAGE BODY
    # inside the wallet card. Both consuming apps mount the modal host in
    # application.html.erb, which is exactly when that flow is populated, and a
    # bare render with no slot is the common adoption.
    #
    # THIS IS THE ONLY ARRANGEMENT THAT SEES IT. Every other test in this file
    # renders the partial DIRECTLY, and a direct render has no layout flow to
    # leak — the one path that stays clean no matter what the partial does.
    html = render_through_layout("layouts/wallet_picker_probe")

    assert_includes html, "LEAKABLE-PAGE-BODY",
                    "the harness must actually populate the layout flow, or this proves nothing"
    refute_includes inner_html_of(html, "#probe-host"), "LEAKABLE-PAGE-BODY",
                    "the page body leaked into the wallet card"
  end

  def test_the_leak_probe_still_bites
    # THE CONTROL for the test above, and the reason to trust it.
    #
    # "The shipped card is clean" is also what a DEAD probe reports — one that
    # renders nothing, populates no flow, or reads the wrong element. Upstream
    # this exact test shipped inert once (it rendered from the template, where
    # the flow is empty) and passed with the defect restored. So the harness is
    # made to demonstrate the leak on a card that genuinely has it, through the
    # same layout arrangement. If this ever goes green-by-not-leaking, the
    # regression test above is no longer evidence of anything.
    html = render_through_layout("layouts/leak_control_probe")

    assert_includes inner_html_of(html, ".leaky-root"), "LEAKABLE-PAGE-BODY",
                    "the control card must leak, or the probe above cannot see a leak either"
  end

  # --- the mobile Phantom contract -------------------------------------------

  def test_mobile_collapses_phantom_to_a_single_row
    xd = x_data(render_picker)

    # The install list suppresses Phantom on mobile — but only when a deep link
    # can replace the row (see test_the_mobile_collapse_requires_a_deep_link).
    assert_includes xd, "if (self.isMobile && self.canDeepLink && i.name === 'Phantom') return false;"
    # ...and the deep-link row appears only when Phantom is NOT already injected:
    # inside Phantom's own in-app browser the detected row wins.
    assert_includes xd, "return this.isMobile && !this.hasWallet('Phantom') && this.canDeepLink;"
  end

  def test_the_mobile_collapse_requires_a_deep_link
    # WHY THIS GATE EXISTS. Without it, adopting this picker replaced an app's
    # dead-end Phantom INSTALL row with a dead BUTTON: install suppressed,
    # deep-link row painted, tap a no-op. An absent capability must not default
    # to the permissive branch.
    xd = x_data(render_picker)

    assert_includes xd, "typeof startPhantomDeepLink === 'function'"
    # BOTH branches consult it, not just the row. Pinning one leaves the other
    # free to diverge, which is the state that produced the dead button.
    assert_includes xd, "self.isMobile && self.canDeepLink && i.name === 'Phantom'"
    assert_includes xd, "!this.hasWallet('Phantom') && this.canDeepLink"
  end

  def test_the_deep_link_row_uses_the_engine_sprite_not_an_app_png
    html = render_picker

    assert_includes html, %(<use href="#se-wallet-phantom">)
    refute_includes html, "phantom-white.png",
                    "the picker must not reach for a per-app asset — it ships to hosts that serve no such file"
  end

  # --- announcement ----------------------------------------------------------

  def test_the_connect_error_announces
    # A connect failure that announces nothing means the user presses the
    # button, the operation fails, red text appears, and assistive tech reports
    # no change at all. Pinned on the partial itself so it cannot regress for a
    # consumer that renders this card and nothing else.
    err = render_picker[%r{<p[^>]*x-text="error"[^>]*>}]

    assert err, "the connect-error paragraph must render"
    assert_includes err, %(role="alert")
  end

  private

  def render_picker(**locals)
    view.render(partial: PARTIAL, locals: locals)
  end

  # Renders a probe layout with a known page body, so view_flow[:layout] is
  # populated by the time the layout's own partials render.
  def render_through_layout(layout)
    view([FIXTURE_PATH]).render(inline: %(<div>LEAKABLE-PAGE-BODY</div>), layout: layout)
  end

  # The x-data ATTRIBUTE only, windowed on the root's class so the match cannot
  # run past it.
  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class="relative"/m, 1].to_s
  end

  def root_inner_html(html)
    inner_html_of(html, "div[x-data]")
  end
end
