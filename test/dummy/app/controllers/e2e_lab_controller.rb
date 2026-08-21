# frozen_string_literal: true

# THE BROWSER LAB — the dummy host's pages that exist so a real browser can drive
# this gem's real onchain surface.
#
# THE RULE THIS CONTROLLER AND ITS VIEWS MUST KEEP: a lab page may set up a
# partial's LOCALS and nothing else. The moment a lab page reimplements what the
# gem does — hand-rolling the modal's markup instead of rendering
# solana_studio/modals/_network_mismatch, or restating the classifier in the page
# instead of loading the shipped .js — the specs start grading the LAB, and the
# lane reports green over gem code no browser ever touched. That failure is
# invisible: every spec still passes. test/lib/e2e_lane_contract_test.rb asserts
# the pages render by name and carry no logic of their own.
#
# ASSET DELIVERY is the HOST's job, and a gem has no asset pipeline — so the dummy
# does what every host does and serves them by path. e2e/boot.rb copies the gem's
# REAL app/assets/javascripts/solana_studio/network_guard.js into
# test/dummy/public/e2e, so the bytes a spec drives are the bytes a consumer gets.
# A spec that drove a re-typed copy would prove nothing about what ships.
class E2eLabController < ActionController::Base
  layout "e2e_lab"

  # The network the lab pretends to be on. A host publishes this from its own
  # Solana config; the lab publishes it as a page local, which is the same
  # relationship every lab page has to the thing it sets up.
  LAB_CLUSTER = "devnet"
  LAB_ENVIRONMENT = "qa"

  def guard
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end

  def modal
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end
end
