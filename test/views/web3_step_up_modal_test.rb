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
    refute_includes render_card(modal_store: "dsModals"), "$store.modals.current()",
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

  private

  def render_card(**locals)
    view.render(partial: PARTIAL, locals: locals)
  end

  def x_data(html)
    html[/x-data="(.*?)"\s*\n?\s*class=/m, 1].to_s
  end
end
