source "https://rubygems.org"

gemspec

# The gem itself declares NO Rails dependency — lib/solana_studio/engine.rb is
# required only when a host has already loaded Rails. railties is here as a
# development dependency purely so the suite can prove BOTH directions of that
# conditional: the engine defines under Rails, and stays absent without it.
group :development, :test do
  gem "railties", "~> 8.0"
  gem "actionpack", "~> 8.0"
  gem "actionview", "~> 8.0"
  gem "puma", "~> 6.0"
  # The MODAL HOST and the shared modal blocks this gem's partial renders through.
  # Development-only: a consumer already bundles studio-engine, and making it a
  # runtime dependency would drag a Rails engine into every plain-Ruby consumer
  # of this gem — the exact coupling lib/solana_studio/engine.rb exists to avoid.
  gem "studio-engine", "~> 0.57"
  gem "minitest", "~> 5.0"
  gem "rake"
end
