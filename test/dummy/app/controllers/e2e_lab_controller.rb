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
# invisible: every spec still passes. test/e2e_lane_contract_test.rb asserts
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

  # Published to the layout so the lab declares its cluster on <body> the way a
  # host does. The deep link reads document.body.dataset.solanaCluster and warns
  # loudly when it is missing; a lab that let it fall back to the default would
  # leave that plumbing untested and the console noisy.
  helper_method :lab_cluster
  def lab_cluster = LAB_CLUSTER

  def guard
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end

  def modal
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end

  # The Phantom mobile deep link. Renders the gem's partial only when asked, so one
  # page can serve BOTH states of the gate that depends on it — see the view.
  #
  # No ivar of its own: the deep link reads its cluster off the body's
  # data-solana-cluster, which the LAYOUT publishes exactly as a host does.
  def phantom_deeplink
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end

  # The two wallet modals' FAILURE path. No ivar and no locals of its own: both
  # partials take every input through local_assigns.fetch and read the rest off
  # the modal store's props, so the page's whole job is to render them by name
  # and supply the host globals they reach for. See the view.
  def wallet_failure
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end

  # The redirect transport. No ivar and no locals: the whole surface under test
  # is the four shipped scripts the LAYOUT loads, exactly as a host loads them.
  # The page's only job is to exist at a URL a browser can navigate away from and
  # back to — which is the one thing no other tier can stage.
  def wallet_transport
    @network_json = Solana::Network.describe(LAB_CLUSTER, environment: LAB_ENVIRONMENT).to_json
  end
end
