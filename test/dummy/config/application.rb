# frozen_string_literal: true

# The minimal Rails host the browser lane drives.
#
# Smaller than studio-engine's equivalent on purpose: this gem's onchain surface
# is a partial and a script, so there is no ActiveRecord, no mailer, and no
# database.yml. A lab page's inputs are locals and a data attribute, which means
# there is no row for a spec to seed and no state for anything to truncate
# underneath it.
#
# TWO engines load here, and both are required:
#   · solana-studio  — the gem under test, which contributes the modal partial
#                      and network_guard.js
#   · studio-engine  — the MODAL HOST and the shared modal blocks the partial
#                      renders through. Without it the partial raises on
#                      `studio/modals/blocks/card_header` and the lane would be
#                      grading a page that never rendered.
require "rails"
require "action_controller/railtie"
require "action_view/railtie"

# BEFORE `require "studio"`, and not optional: studio-engine's lib/studio.rb
# evaluates `15.minutes` at load time, which is an ActiveSupport core extension.
# `require "rails"` alone does not install it, so the engine raises
# NoMethodError on Integer during require. A host app never hits this because
# its Rails boot has already loaded the core extensions by then.
require "active_support/all"

require "studio"
require "solana_studio"

module Dummy
  class Application < Rails::Application
    # Pin the root. With no config.ru marker, Rails falls back to Dir.pwd — the
    # gem root — and looks for this app's config in the wrong place.
    config.root = File.expand_path("..", __dir__)

    config.load_defaults 8.1
    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "solana-studio-e2e-lab-secret-key-base-not-a-real-secret"

    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal

    # An unhandled exception must reach the spec as a failed page, not as a
    # rendered 500 that a "does the modal exist?" assertion would read as a
    # simple absence.
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = false

    # studio-engine's `studio.assets` initializer does
    # `app.config.assets.precompile += [...]` UNGUARDED, and this dummy ships no
    # asset-pipeline gem, so it raises NoMethodError on config.assets during
    # boot. Seed a shim with an Array it can append to. (This gem's own
    # solana_studio.assets initializer guards with respond_to? and needs no shim
    # — worth keeping that way; a host without a pipeline is a real shape, which
    # is precisely what this dummy is.)
    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    config.assets = assets
  end
end
