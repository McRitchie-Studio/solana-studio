# frozen_string_literal: true

module SolanaStudio
  # The gem's OPTIONAL Rails half.
  #
  # solana-studio is a Rails-free gem by design — chain-ops scripts, rake tasks
  # and bare `ruby -e` consumers load Solana::Keypair and Solana::Transaction
  # without ever paying for railties. This file is the one place that assumes
  # Rails, and lib/solana_studio.rb requires it ONLY when Rails::Engine is
  # already defined. Nothing here runs for a non-Rails consumer, and railties is
  # deliberately absent from the gemspec's runtime dependencies: the host app
  # supplies Rails, this engine merely joins it.
  #
  # What the engine adds is the onchain UI surface — the modals and browser
  # guard that every Solana-backed app in the ecosystem would otherwise fork.
  # Rails picks up app/views automatically for any Engine subclass, so a host
  # can `render "solana_studio/modals/network_mismatch"` with no configuration.
  #
  # Namespace is NOT isolated, matching studio-engine. These are partials a host
  # renders into its own modal host, not a mounted sub-application; isolating
  # would scope helpers and routes away from the host for no gain.
  class Engine < ::Rails::Engine
    # Sprockets hosts (mcritchie-studio, turf-monster) need every gem-shipped
    # asset named here or it 404s in production with no local warning —
    # propshaft hosts serve everything on config.assets.paths and ignore this.
    # Guarded because a propshaft host has no config.assets.precompile at all.
    initializer "solana_studio.assets" do |app|
      next unless app.config.respond_to?(:assets)
      next unless app.config.assets.respond_to?(:precompile)

      app.config.assets.precompile += %w[
        solana_studio/network_guard.js
      ]
    end
  end
end
