require_relative "test_helper"

# [unit] The contributed SIGN-IN credential — this gem's half of studio-engine's
# auth-modal credential slot.
#
# The arrangement: studio-engine owns the auth modal, because every app signs
# people in and most apps are web2. This gem owns the WALLET button, because only
# a web3 app has wallets. The engine looks for a partial at a fixed path and
# renders whatever it finds; being installed is the entire registration.
#
# WHAT THIS SIDE CAN HONESTLY CLAIM. This suite is Rails-free by design (see
# test/engine_test.rb), so it cannot render. What it CAN pin is the half of the
# contract visible in the source: that the file sits where the engine looks, and
# that the scope members it borrows from the modal are actually used.
# Compilation is covered for free by ViewsTest's glob.
#
# THE RENDER TIER IS test/views/auth_wallet_credential_test.rb, IN THIS REPO.
# This comment used to send readers to studio-engine's
# test/views/auth_credential_slot_test.rb, which does not exist — the engine
# keeps only its own style-guide specimens
# (test/views/style_web3_specimens_test.rb) and never asserted this partial's
# locals. The distinction matters more since the click grew a seam: the default
# handler is assembled by ERB and appears NOWHERE in this file's source, so
# everything below is now a claim about the TEMPLATE, and the claims about the
# OUTPUT live next door.
class AuthCredentialTest < Minitest::Test
  PATH = File.expand_path("../app/views/solana_studio/auth/_wallet_credential.html.erb", __dir__)

  # ERB comments stripped before every assertion below. This file's header
  # DESCRIBES the contract in prose, so a bare grep for "attested" would match
  # the paragraph explaining the age gate just as happily as the gate itself —
  # and would keep passing after someone deleted the gate. Assert on code only.
  def source
    @source ||= File.read(PATH).gsub(/<%#.*?%>/m, "")
  end

  def test_the_partial_sits_where_the_engine_looks
    # The path IS the wiring. There is no registration call, no initializer and
    # no config entry to catch a rename — a moved file simply stops being found
    # and the button silently stops existing, in every consuming app at once.
    assert File.file?(PATH), "the engine resolves solana_studio/auth/_wallet_credential by path"
  end

  def test_the_age_gate_guards_the_click
    # Every other credential CTA in the engine's modal calls attested() before
    # doing anything. A contributed button that skipped it would be the one way
    # around the legal-age gate, and it would look completely normal.
    assert_match(/@click="attested\(\) &&/, source,
                 "the click handler must consult the modal's age gate first")
  end

  def test_visibility_follows_the_modal_toggle
    # methodOn('wallet') is the engine's shared per-method switch, which the
    # style guide's specimen toggles drive. Binding to anything else would leave
    # a button the guide cannot turn off. Matched as a SUBSTRING of the gate now
    # that the call sits behind a typeof test — the concern is that the shared
    # toggle is still what gets consulted, not the exact spelling around it.
    assert_match(/x-show="[^"]*methodOn\('wallet'\)/, source)
  end

  def test_the_gate_tolerates_a_host_that_never_defined_the_toggle
    # A BARE methodOn('wallet') THROWS in a host without the member, Alpine
    # grades the throw as FALSY, and the button SILENTLY NEVER RENDERS — no
    # error a user can see, nothing in the page to debug. Measured in Chromium
    # against the vendored Alpine 3.16.1; it is what blocked Turf Monster's
    # adoption of this partial.
    #
    # Duplicated from the render tier ON PURPOSE. This suite is Rails-free, so
    # it is the copy that still runs when a view context cannot boot at all.
    assert_includes source,
                    %(x-show="typeof methodOn === 'function' ? methodOn('wallet') : true")
  end

  def test_the_click_tail_is_an_optional_local
    # OPTIONAL, unlike modal_store, and that asymmetry is the design: a wrong
    # store name fails as a dead button so it has no default, while an absent
    # on_click has an obviously right answer — what every host did before the
    # seam existed.
    #
    # BOUND TO THE CONCERN, NOT TO ONE SPELLING OF IT. This asserted
    # /local_assigns\.fetch\(:on_click\)\s*do/ until the precedence fix traded
    # fetch-with-block for a key? branch, and it went red over a change that
    # preserved every property it existed to protect — including, verified next
    # door, byte-identical output for a host that passes no local. An assertion
    # that names one legal way to write a default breaks on every legal refactor
    # of that default, and an assertion that cries wolf is one that gets
    # loosened. The concern is that on_click is READ, and read in a way that
    # tolerates its ABSENCE.
    assert_includes source, ":on_click", "the template must still read the on_click local"
    refute_match(/local_assigns\.fetch\(:on_click\)(?!\s*(do\b|\{|,))/, source,
                 "a fetch(:on_click) with no default or block RAISES for the host " \
                 "that passes no local, which is the whole additive contract of the seam")
  end

  def test_an_overridden_tail_is_parenthesised_before_it_is_emitted
    # THE DEFECT THIS PINS: `&&` binds TIGHTER than `||`, `?:` and comma, so an
    # override whose top-level operator is one of those reparses and its tail
    # runs even when attested() returned FALSE — a click past a legal-age gate
    # it had just failed. Measured in Chromium against the vendored Alpine
    # 3.16.1: an on_click of `saveCart() || openWalletHub()` ran openWalletHub.
    #
    # DUPLICATED FROM THE RENDER TIER ON PURPOSE, exactly like the typeof guard
    # above: this suite is Rails-free, so it is the copy that still runs when a
    # view context cannot boot at all.
    #
    # AND IT IS THE WEAKER COPY, stated plainly so nobody reads a green run here
    # as the proof. This matches CHARACTERS. The authority is
    # test/views/auth_wallet_credential_test.rb, which evaluates the emitted
    # handler in a JS engine and asserts the gate CONTROLS the tail — a property
    # of the parse that no source match can see.
    assert_match(/\(\#\{\s*local_assigns\[:on_click\]\s*\}\)/, source,
                 "an overridden tail must be parenthesised where it is built, or a " \
                 "top-level ||, ?: or comma reparses past the age gate")
  end

  def test_the_click_tail_is_emitted_unescaped
    # Without raw, ActionView escapes the handler and a host's && ships as an
    # entity. It still WORKS, because the HTML parser decodes the attribute
    # before Alpine reads it — so the page looks perfect and only the shipped
    # bytes are wrong, which is why nothing else would notice. The render tier
    # asserts the effect on the output; this asserts the marker in the template.
    assert_includes source, %(@click="attested() && <%= raw on_click %>")
  end

  def test_the_store_name_is_a_required_local
    # fetch WITHOUT a default, on purpose. A defaulted store name fails as a
    # button that does nothing when clicked — no error, no log, just a dead CTA
    # — because the style guide's host is "dsModals" and the real one is
    # "modals". Missing beats wrong here.
    assert_includes source, "local_assigns.fetch(:modal_store)"
    refute_match(/local_assigns\.fetch\(:modal_store,/, source,
                 "modal_store must have no default")
  end

  def test_the_swap_target_and_props_match_the_pickers_contract
    # The picker reads backTo to draw its back button and ageAttested to skip
    # asking a second time. Both are part of studio-engine's wallet-connect
    # contract, so they are pinned here rather than left to a reader to notice.
    assert_includes source, "swap('wallet-connect'"
    assert_includes source, "backTo: 'auth'"
    assert_includes source, "ageAttested: true"
  end

  def test_the_brand_mark_gradient_id_is_namespaced
    # Two Solana marks on one page would otherwise share a gradient id, and the
    # SECOND one silently paints with the first one's stops. Namespaced to this
    # gem so a host that draws its own mark cannot collide with it.
    assert_includes source, "solana-studio-auth-grad"
    refute_includes source, %(id="auth-solana-grad"),
                    "the engine's old unnamespaced id must not come back"
  end

  def test_the_partial_ships_no_asset_request
    # A host on sprockets 404s any gem asset not named in a precompile list, and
    # the failure is invisible locally. The mark is inline SVG for that reason;
    # an img/src or asset helper creeping in would break the button's brand on
    # exactly the two apps that use it.
    refute_match(/image_tag|asset_path|<img/, source,
                 "the brand mark must stay inline, not become an asset request")
  end
end
