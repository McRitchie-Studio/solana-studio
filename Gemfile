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
  # The RENDER tier (test/views/) parses the card it just rendered. DECLARED
  # rather than leaned on as actionview's transitive dependency, because the
  # suite requires it directly and a transitive it does not name can vanish
  # under an unrelated dependency bump. A hand-rolled tag scanner is not the
  # cheaper option here — it is the known-WRONG one: the version this replaced
  # read the wallet row's void <img> as an open element and answered "one root"
  # for any number of roots.
  gem "nokogiri", "~> 1.19"
  gem "minitest", "~> 5.0"
  gem "rake"
end
