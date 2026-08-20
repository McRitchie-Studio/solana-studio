require_relative "solana/keypair"
require_relative "solana/borsh"
require_relative "solana/client"
require_relative "solana/transaction"
require_relative "solana/spl_token"
require_relative "solana/system_program"
require_relative "solana/nonce_account"
require_relative "solana/auth_verifier"
require_relative "solana/network"

module SolanaStudio
  VERSION = "0.5.0"
end

# The Rails half of the gem — views, assets, and the browser network guard.
# Loaded only inside a Rails process; a plain-Ruby consumer never sees it and
# never needs railties installed. See lib/solana_studio/engine.rb.
require_relative "solana_studio/engine" if defined?(::Rails::Engine)
