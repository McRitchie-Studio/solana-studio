# frozen_string_literal: true

require_relative "view_render_support"

# [unit] solana_studio/modals/_web3_step_up — the wallet step-up card, asserted
# at the RENDER tier.
#
# This card is unusual, and the difference is what most of these tests defend:
# it is the REAL partial a host renders in production, not a style-guide
# specimen with a private copy living in each app. That only holds while every
# host hook is a LOCAL WITH A WORKING DEFAULT — otherwise the "shared" card is
# one app's card with extra steps, and the second adopter forks it.
#
# So the shape of this file is deliberate: for each hook, assert the default AND
# assert the override, and assert that the override left nothing behind. A
# half-swapped hook is the failure that actually ships, because the card still
# renders and only misbehaves in a browser it was not mounted in.
class Web3StepUpModalTest < Minitest::Test
  include ViewRenderSupport

  PARTIAL = "solana_studio/modals/web3_step_up"

  # --- the silent-no-op guard ------------------------------------------------

  def test_the_x_data_attribute_contains_no_double_quotes_or_backticks
    # A double quote inside the double-quoted x-data closes the attribute early
    # and Alpine mounts the whole component as a SILENT NO-OP: the markup still
    # renders, so every other assertion in this file still passes while the card
    # is dead on the page. It has bitten this ecosystem twice, so every
    # step-machine modal carries this guard.
    #
    # Read from the RENDERED attribute, not the source file. A local or an
    # interpolated default is exactly how a quote gets in, and the source form
    # `<%= modal_store %>` cannot show that.
    xd = x_data(render_card)

    refute_empty xd, "could not locate the x-data attribute — did the root element change?"
    refute_includes xd, '"'
    refute_includes xd, "`"
  end

  # --- the two shapes --------------------------------------------------------

  def test_it_renders_the_standard_wallet_row_not_a_filled_cta
    html = render_card

    # The row shape the connect picker uses, so a wallet reads identically
    # everywhere it is offered.
    assert_includes html, "w-full flex items-center gap-3 p-3 rounded-xl bg-surface-alt border border-strong"
    refute_includes html, "btn btn-primary btn-lg"
    assert_includes html, "'#se-wallet-' + provider", "the row paints the brand's own sprite"
    assert_includes html, "Installed"
  end

  def test_the_row_glows_because_it_is_the_one_thing_to_press
    html = render_card

    assert_includes html, "pulse-cta"
    assert_includes html, "--pulse-cta-color: var(--color-primary)"
  end

  def test_both_provider_states_ship_and_the_fallback_is_not_a_dead_end
    html = render_card

    # One template each. The card cannot know at render time which it will be —
    # the provider arrives as a prop — so BOTH must ship in the markup.
    assert_includes html, %(x-text="providerLabel"), "the remembered-brand row"
    assert_includes html, "Connect your wallet", "the no-brand fallback"
    # ...and the fallback's mark is a DRAWN wallet, not an emoji. The first pass
    # used U+1F45B PURSE, which renders as a pink handbag inches from Phantom's
    # real brand mark — the one thing on the card belonging to no design system.
    # Pinned by CODEPOINT because the next well-meaning emoji looks fine in a
    # commit diff and wrong on screen, and by entity because ERB may emit either.
    refute_includes html, "\u{1F45B}"
    refute_includes html, "&#128091;"
    assert_includes html, "get canOneClick() { return !!this.provider && !this.providerMissing; }"
  end

  def test_presence_is_polled_never_read_once_at_mount
    # Wallet registration fills in ASYNCHRONOUSLY and this card auto-opens on the
    # render right after auth — the worst possible moment. A single early read
    # would badge an installed wallet as missing with no way to correct it.
    html = render_card

    assert_includes html, "wallet-standard:register-wallet"
    assert_includes html, "setInterval"
    assert_includes html, "clearInterval", "and it must stop polling — this card can be reopened"
    assert_includes html, "removeEventListener('wallet-standard:register-wallet'",
                    "a card that can be reopened must drop its listener, or each open leaks another"
  end

  def test_presence_is_read_through_the_host_wallet_provider_seam
    # WHY THERE IS NO LEGACY-VS-WALLET-STANDARD ASSERTION HERE, stated so the
    # next reader does not add one and think they widened the coverage.
    #
    # Phantom exposes TWO provider interfaces — the legacy window.solana object
    # and the Wallet Standard registry — and a spec pinned to one of them
    # certifies half the surface. This card touches NEITHER. It reads
    # window.walletProvider, the host's own abstraction, which is the single
    # place that reconciles the two. Asserting a legacy path here would pin a
    # branch this partial does not contain.
    html = render_card

    assert_includes html, "window.walletProvider && window.walletProvider.available"
    assert_includes html, "window.walletProvider.get(name)"
  end

  # --- host hooks are locals, with defaults ----------------------------------

  def test_the_modal_store_is_a_local_so_a_host_can_mount_its_own
    assert_includes render_card, "$store.modals.current()"
    assert_includes render_card(modal_store: "dsModals"), "$store.dsModals.current()"
    refute_includes render_card(modal_store: "dsModals"), "$store.modals.",
                    "a half-swapped store leaves the card reading a host it is not mounted in"
  end

  def test_the_picker_id_and_the_back_target_are_locals
    # Defaults first: these two ids are the wiring every consumer inherits by
    # rendering the card bare, so they are the values most likely to be depended
    # on and least likely to be noticed changing.
    bare = render_card
    assert_includes bare, "swap('wallet-connect'"
    assert_includes bare, "backTo: 'web3-step-up'"

    html = render_card(picker_modal_id: "pick-a-wallet", modal_id: "step-up")
    assert_includes html, "swap('pick-a-wallet'"
    assert_includes html, "backTo: 'step-up'"
    refute_includes html, "swap('wallet-connect'",
                     "a half-swapped picker id sends Back to a modal the host never registered"
  end

  def test_the_dismissal_event_is_a_local_and_the_card_never_opens_the_next_modal
    # The HOST decides what follows — typically releasing an onboarding chain it
    # held while this card had the screen. A partial that opened the next modal
    # itself would make that decision for every app that renders it.
    #
    # BOTH SIDES, and the default is not decoration. Asserting only the override
    # leaves the shipped default — the string every current consumer actually
    # listens for — pinned by nobody; proved by mutation, where changing it went
    # green against an override-only version of this test.
    assert_includes render_card, "CustomEvent('web3-step-up-dismissed')"

    html = render_card(dismiss_event: "stepped-up")
    assert_includes html, "CustomEvent('stepped-up')"
    refute_includes html, "CustomEvent('web3-step-up-dismissed')",
                     "a half-swapped event leaves the host listening for a name the card no longer fires"
    refute_includes html, "open('onboarding"
  end

  def test_the_heading_and_subtext_are_locals
    # The default heading is the card's shipped copy, and a card that renders no
    # heading at all still passes an override-only assertion.
    assert_includes render_card, "Sign in with your wallet"

    html = render_card(heading: "Prove your wallet", subtext: "Custom why.")
    assert_includes html, "Prove your wallet"
    assert_includes html, "Custom why."
    refute_includes html, "Sign in with your wallet", "the override must replace the default, not sit beside it"
  end

  # --- the escape hatch ------------------------------------------------------

  def test_the_escape_hatch_ships_by_default_and_takes_a_host_url
    # A self-custody wallet is the one credential a host cannot reset for a
    # user, so the default must REACH someone rather than being opt-in.
    assert_includes render_card, "/help"
    assert_includes render_card, "Can&rsquo;t access your wallet?"
    assert_includes render_card, "Get help", "the default label ships too, not just the default URL"

    overridden = render_card(help_url: "/support", help_label: "Contact us")
    assert_includes overridden, "/support"
    assert_includes overridden, "Contact us"
  end

  def test_dropping_the_escape_hatch_takes_a_deliberate_nil
    refute_includes render_card(help_url: nil), "Can&rsquo;t access your wallet?"
  end

  def test_the_card_is_dismissible
    # Advisory by construction — enforcement belongs to the host's on-chain
    # gates, never to this card. A card that could not be closed would lock a
    # legitimate owner out over a wallet they merely cannot reach right now.
    assert_includes render_card, "Not now"
    assert_includes render_card, %(aria-label="Close")
  end

  # --- signing ---------------------------------------------------------------

  def test_signing_runs_the_wallet_login_not_the_account_link_path
    # linkMode binds a wallet to the current user but never grants the on-chain
    # session — the thing this card exists to obtain.
    assert_includes render_card, "solanaConnectAndVerify(name, { linkMode: false })"
  end

  def test_it_degrades_rather_than_throwing_when_the_host_provides_no_wallet_js
    # The partial ships to any app that renders it, including one that has not
    # wired the global. A TypeError inside an Alpine handler is silent.
    assert_includes render_card, "typeof window.solanaConnectAndVerify !== 'function'"
  end

  # --- structure and announcement --------------------------------------------

  def test_single_root_element
    # Mounted inside the host's <template x-if>, so a second top-level node is
    # dropped silently.
    html = render_card.strip

    assert_equal 1, element_children_count(html)
    assert_equal 2, element_children_count("#{html}\n<div>second root</div>"),
                 "control: the counter must be able to see a second root"
  end

  def test_the_step_up_error_announces
    err = render_card[%r{<p[^>]*x-text="error"[^>]*>}]

    assert err, "the error paragraph must render"
    assert_includes err, %(role="alert")
  end

  # --- the polish pass, 2026-09-06 -------------------------------------------
  #
  # NONE of the 17 tests above referenced the lock emoji, the footnote, or the
  # "Use a different wallet" row. Removing all three left the suite green, which
  # means the card's most visible surface was unpinned — so these tests are the
  # ones that would have caught this change, not a record that it happened.
  #
  # THE FIRST VERSION OF THIS SECTION WAS INERT, and it is written down here
  # because the failure mode is invisible from inside the file. Those tests
  # asserted `'#se-wallet-' + provider` and `canOneClick` against the WHOLE
  # rendered card, and both strings already lived elsewhere in it — the first in
  # the 36px CTA row, the second in the x-data getter. Deleting the entire brand
  # header left the suite at 22 runs / 118 assertions / 0 failures while a probe
  # confirmed the header was gone from the HTML. Six of nine mutants survived.
  #
  # The fix is STRUCTURAL, not a longer string: `brand_header` is the block
  # immediately ABOVE the heading and `header_branch` is one x-if branch of it,
  # so no assertion below can be satisfied by markup somewhere else in the card.
  # `test_the_header_slice_can_come_up_empty` is the control that keeps that
  # true — without it every assertion here would pass vacuously against a slice
  # that had silently stopped finding anything.

  def test_the_header_slice_can_come_up_empty
    # THE CONTROL. Strip the header out of the rendered card and the slice must
    # stop finding a brand branch. If this test goes green with the strip
    # removed, `brand_header` is reading something that is not the header and
    # the two tests below are free.
    html     = render_card
    beheaded = html.sub(%r{<div class="text-center mb-4">.*?</div>\s*}m, "")

    refute_equal html, beheaded, "control: the header must be findable before it can be removed"
    assert_nil header_branch(brand_header(beheaded), "canOneClick"),
               "with the header stripped the slice must find no remembered-brand branch"
    assert_nil header_branch(brand_header(beheaded), "!canOneClick"),
               "...nor a no-brand one"
    # ...and the CTA row, which carries the same sprite binding, is STILL there —
    # so what the control proves is that the slice ignores it, not that the
    # string vanished from the document.
    assert_includes beheaded, "'#se-wallet-' + provider"
  end

  def test_the_card_leads_with_a_wallet_mark_not_a_padlock
    html   = render_card
    header = brand_header(html)

    assert header, "the card must LEAD with a block of its own, above the heading"

    # A padlock is a security glyph, not the object being asked for. Refuted in
    # BOTH forms: `&#128274;` renders identically to the literal codepoint and
    # sails straight past a codepoint-only assertion.
    refute_includes html, "\u{1F510}"
    refute_includes html, "&#128274;"

    # Remembered brand: THAT wallet's mark, at header size. The size is part of
    # the assertion because the CTA row below paints the same sprite at w-9 —
    # an assertion that ignores it is satisfied by the button.
    remembered = header_branch(header, "canOneClick")
    assert remembered, "the remembered-brand half of the header must ship"
    assert_includes remembered, "'#se-wallet-' + provider",
                    "bound to the prop, never to one hardcoded brand"
    assert_includes remembered, "w-14 h-14", "and drawn at header size, not the button's"

    # No remembered brand: the neutral billfold this file already draws for its
    # no-brand button, rather than card_header's tinted check.
    fallback = header_branch(header, "!canOneClick")
    assert fallback, "the no-brand half of the header must ship too"
    assert_includes fallback, "w-7 h-7 text-secondary", "the neutral billfold, on theme tokens"
    refute_includes fallback, "se-wallet-",
                    "the no-brand branch has no brand to paint — a swap of the two puts one here"
  end

  def test_the_address_line_appears_only_when_there_is_an_address
    body = body_block(render_card)

    assert body, "the card must carry a body block under the heading"

    guarded = body.css("template").find { |t| t["x-if"] == "walletHint" }
    assert guarded, "the address line must sit inside an x-if on walletHint"
    assert_includes guarded.inner_html, "Please sign in with wallet"
    assert_includes guarded.inner_html, %(x-text="walletHint"),
                    "the address itself is the point of the line"

    # CONDITIONAL, and that is the requirement: a card with no remembered wallet
    # must not print a sentence with a blank where the address goes. Asserted by
    # REMOVING every template from the body and reading what is left, so a
    # second unconditional copy is caught as well as a dropped guard.
    unguarded = body.dup
    unguarded.css("template").each(&:remove)
    refute_includes unguarded.inner_html, "Please sign in with wallet"
    refute_includes unguarded.inner_html, "walletHint"
  end

  def test_the_body_is_one_line_again
    html = render_card

    assert_includes body_block(html).inner_html, "Your account is secured by a Solana wallet."
    # The four-line explanation of why the session cannot sign on-chain was true
    # and more than someone standing in front of a button needs.
    refute_includes html, "this session can", "the session-cannot-sign explanation is gone"
    refute_includes html, "on-chain actions still need your wallet"
  end

  def test_the_card_runs_from_the_cta_to_not_now
    html = render_card

    refute_includes html, "Use a different wallet",
                    "the alternate-wallet row was dropped (operator call)"
    refute_includes html, "Signing proves the wallet is yours",
                    "the footnote was dropped; the address moved up into the body"
  end

  def test_the_body_block_carries_the_margin_that_used_to_be_an_accident
    # Not a taste change. The old callsite passed a BLOCK to card_header, which
    # wraps `yield` in a <p> of its own, so the card emitted <p><p> and the
    # parser auto-closed it into a stray EMPTY paragraph — and that empty
    # paragraph was the body-to-CTA gap. Hand-rolling the header removed it, so
    # the margin has to be declared. Asserted on the block that HOLDS the copy:
    # an mb-5 that drifts onto an empty neighbour restores the old accident.
    body = body_block(render_card)

    assert body, "the body copy must sit in a block of its own"
    assert_includes body["class"].to_s.split, "mb-5", "that block carries the bottom margin"
    assert_includes body.inner_html, "Your account is secured by a Solana wallet.",
                    "the margin is on the block holding the copy, not on an empty neighbour"
  end

  private

  def render_card(**locals)
    view.render(partial: PARTIAL, locals: locals)
  end

  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class=/m, 1].to_s
  end

  # THE BRAND HEADER, sliced STRUCTURALLY: the element immediately above the
  # heading. Not by class, because a class-matched slice makes the mark tests
  # fail for a margin edit; not by string, because the strings the header emits
  # are the CTA row's strings too. "The block the card leads with" is also the
  # claim being tested, so the slice and the acceptance criterion are the same
  # sentence. Returns a Nokogiri node, or nil when nothing precedes the heading.
  def brand_header(html)
    Nokogiri::HTML5.fragment(html).at_css("h3")&.previous_element
  end

  # The body copy block: the element immediately BELOW the heading.
  def body_block(html)
    Nokogiri::HTML5.fragment(html).at_css("h3")&.next_element
  end

  # One x-if branch of a sliced block, as raw HTML. Matched on the GUARD, so
  # swapping the two branches moves the markup to the other guard and every
  # assertion about it fails — a slice keyed on position alone cannot see that.
  def header_branch(node, guard)
    node&.css("template")&.find { |t| t["x-if"] == guard }&.inner_html
  end
end
