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
# test/engine_test.rb), so it cannot render — rendering needs the engine's view
# context, and those assertions live in studio-engine's
# test/views/auth_credential_slot_test.rb. What it CAN pin is the half of the
# contract that is visible in the source: that the file sits where the engine
# looks, and that the three scope members it borrows from the modal are actually
# used. Compilation is covered for free by ViewsTest's glob.
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
    # a button the guide cannot turn off.
    assert_includes source, %(x-show="methodOn('wallet')")
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
