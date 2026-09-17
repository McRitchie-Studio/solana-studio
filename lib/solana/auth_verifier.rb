require "ed25519"
require_relative "ed25519_strict"
require "openssl"

module Solana
  # Verifies a Solana wallet signature against an externally-stored nonce.
  # Pure module — no Rails / no session coupling. Host apps adapt their
  # session storage and call `Solana::AuthVerifier.verify!`.
  #
  # **IMPORTANT — caller is responsible for replay prevention.** The host
  # MUST invalidate `stored_nonce` immediately after this method returns
  # (success OR failure). The canonical Rails-session adapter pattern is:
  #
  #     stored_nonce = session.delete(:solana_nonce)
  #     nonce_at     = session.delete(:solana_nonce_at)
  #     Solana::AuthVerifier.verify!(
  #       message: ..., signature_b58: ..., pubkey_b58: ...,
  #       expected_host: request.host,
  #       stored_nonce: stored_nonce, nonce_at: nonce_at
  #     )
  #
  # The `session.delete(...)` BEFORE the verify! call is what prevents
  # replay — once consumed, the nonce can never satisfy verify! again.
  # See turf-monster `app/controllers/concerns/solana/session_auth.rb`
  # for the production adapter.
  module AuthVerifier
    class VerificationError < StandardError; end

    # Default max nonce age in seconds (5 minutes).
    NONCE_MAX_AGE = 300

    ED25519_PUBKEY_BYTES = 32
    ED25519_SIGNATURE_BYTES = 64

    # Verifies that `signature_b58` is a valid Ed25519 signature over
    # `message` made by `pubkey_b58`, AND that the message is bound to
    # `expected_host` (its opening token), AND that the `Nonce: ...` field
    # matches `stored_nonce`, AND that the nonce is not stale.
    #
    # Returns the verified public key (base58 string) on success.
    # Raises Solana::AuthVerifier::VerificationError on any failure.
    #
    # @param message [String] the signed message (must contain `Nonce: <value>`)
    # @param signature_b58 [String] base58-encoded Ed25519 signature
    # @param pubkey_b58 [String] base58-encoded public key
    # @param expected_host [String] host the signed message must name as its
    #   opening token — rejects signatures the user made for any other domain
    #   (OPSEC-018)
    # @param stored_nonce [String, nil] the nonce the host issued + remembers
    # @param nonce_at [Integer, nil] Unix timestamp when the nonce was issued
    # @param max_age [Integer] seconds before a nonce expires (default 300)
    def self.verify!(message:, signature_b58:, pubkey_b58:, expected_host:, stored_nonce:, nonce_at: nil, max_age: NONCE_MAX_AGE)
      raise VerificationError, "No nonce provided" if stored_nonce.nil? || stored_nonce.empty?
      raise VerificationError, "No expected_host provided" if expected_host.nil? || expected_host.to_s.empty?

      if nonce_at && (Time.now.to_i - nonce_at.to_i) > max_age
        raise VerificationError, "Nonce expired"
      end

      sig_bytes = Solana::Keypair.decode_base58(signature_b58)
      pub_bytes = Solana::Keypair.decode_base58(pubkey_b58)

      # Length-check BEFORE handing to Ed25519::VerifyKey to surface a clean
      # error (instead of letting the library raise ArgumentError, which the
      # rescue below would convert into a misleading "Signature verification
      # failed" message).
      unless pub_bytes.bytesize == ED25519_PUBKEY_BYTES
        raise VerificationError, "Public key must be #{ED25519_PUBKEY_BYTES} bytes, got #{pub_bytes.bytesize}"
      end
      unless sig_bytes.bytesize == ED25519_SIGNATURE_BYTES
        raise VerificationError, "Signature must be #{ED25519_SIGNATURE_BYTES} bytes, got #{sig_bytes.bytesize}"
      end

      # Ed25519::VerifyKey checks the equation and nothing else, so a
      # small-order or non-canonical key — an address with no secret key behind
      # it — can pass it. Refuse those, and a malformed R or S, before it runs.
      # See Solana::Ed25519Strict.
      if (problem = Solana::Ed25519Strict.public_key_problem(pub_bytes))
        raise VerificationError, "Public key #{problem}"
      end
      if (problem = Solana::Ed25519Strict.signature_problem(sig_bytes))
        raise VerificationError, "Signature #{problem}"
      end

      verify_key = Ed25519::VerifyKey.new(pub_bytes)
      verify_key.verify(sig_bytes, message)

      claimed_nonce = message.match(/Nonce: (\w+)/)&.captures&.first
      unless claimed_nonce && constant_time_eq?(claimed_nonce, stored_nonce)
        raise VerificationError, "Invalid nonce"
      end

      # OPSEC-018: bind the signature to the host. The signed message must name
      # the host as its opening token (SIWS-style: "<host> wants to sign in…").
      # Without this, a signature the user produced for any other dApp — over a
      # message that happens to carry the same nonce — would satisfy verify!.
      unless message.start_with?("#{expected_host} ")
        raise VerificationError, "Message is not bound to host #{expected_host}"
      end

      pubkey_b58
    rescue Ed25519::VerifyError => e
      raise VerificationError, "Signature verification failed: #{e.message}"
    end

    # Constant-time string equality, sourced from OpenSSL's fixed_length_secure_compare
    # (available since Ruby 2.5+). Returns false (not raise) if lengths differ.
    # Used for nonce comparison so attackers can't time-leak match progress.
    def self.constant_time_eq?(a, b)
      a = a.to_s
      b = b.to_s
      return false unless a.bytesize == b.bytesize
      OpenSSL.fixed_length_secure_compare(a, b)
    end
  end
end
