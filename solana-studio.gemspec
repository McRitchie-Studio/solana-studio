# The version is NOT written here. It lives in lib/solana_studio/version.rb —
# the file config/release_repos.yml registers as this gem's `version_file` and
# the release conductor rewrites during a sweep. Keeping it out of the gemspec
# is what lets a PR edit the manifest below (spec.files, dependencies, metadata)
# without tripping bin/dor-check's release-owned-file refusal.
require_relative "lib/solana_studio/version"

Gem::Specification.new do |spec|
  spec.name          = "solana-studio"
  spec.version       = SolanaStudio::VERSION
  spec.authors       = ["Alex McRitchie"]
  spec.email         = ["solana-studio@mcritchie.studio"]

  spec.summary       = "Ruby primitives for Solana: JSON-RPC client, Ed25519 keypairs, Borsh serialization, transaction builder, wallet signature verifier"
  spec.description   = "A lightweight Ruby gem providing generic Solana building blocks — JSON-RPC client with retry, Ed25519 keypair management, Borsh encoding/decoding, transaction builder with PDA derivation and Anchor discriminators, SPL Token instruction helpers, and a pure-Ruby wallet-signature verifier (Solana::AuthVerifier)."
  spec.homepage      = "https://github.com/amcritchie/solana-studio"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri"    => "https://github.com/amcritchie/solana-studio",
    "source_code_uri" => "https://github.com/amcritchie/solana-studio",
    "bug_tracker_uri" => "https://github.com/amcritchie/solana-studio/issues",
    "changelog_uri"   => "https://github.com/amcritchie/solana-studio/blob/main/CHANGELOG.md"
  }

  # WIDEN THIS WHEN YOU ADD A DIRECTORY. The gem ships a Rails engine as of
  # 0.5.0, and an engine is only its files: a view or asset outside this glob is
  # absent from the published .gem while every local test, every CI lane and the
  # release sweep stay green — the sweep publishes on release MEMBERSHIP, not on
  # content, so nothing downstream inspects what actually got packaged. The
  # failure lands in a consumer app as a missing partial. test/gemspec_test.rb
  # asserts the engine's files are in here for exactly that reason.
  #
  # "lib/**/*.rb" stays .rb-only on purpose (no stray fixtures); app/ is a full
  # glob because it carries .erb and .js, and reject(&File.method(:directory?))
  # keeps directory entries out of the manifest.
  spec.files         = (
    Dir["lib/**/*.rb"] +
    Dir["app/**/*"] +
    ["README.md", "LICENSE", "CHANGELOG.md"]
  ).reject { |f| File.directory?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "ed25519", "~> 1.3"
end
