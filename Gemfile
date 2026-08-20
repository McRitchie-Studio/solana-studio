source "https://rubygems.org"

gemspec

# The gem itself declares NO Rails dependency — lib/solana_studio/engine.rb is
# required only when a host has already loaded Rails. railties is here as a
# development dependency purely so the suite can prove BOTH directions of that
# conditional: the engine defines under Rails, and stays absent without it.
group :development, :test do
  gem "railties", "~> 8.0"
  gem "minitest", "~> 5.0"
  gem "rake"
end
