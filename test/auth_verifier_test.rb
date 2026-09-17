require_relative "test_helper"
require_relative "ed25519_forgery_support"

class AuthVerifierTest < Minitest::Test
  HOST = "turf.example.com"

  # Build a host-bound, nonce-carrying message and sign it with a fresh key.
  def signed_message(host: HOST, nonce: "abc123XYZ")
    kp = Solana::Keypair.generate
    message = "#{host} wants to sign in with your Solana account:\n\nNonce: #{nonce}"
    {
      message: message,
      signature_b58: Solana::Keypair.encode_base58(kp.sign(message)),
      pubkey_b58: kp.to_base58,
      nonce: nonce
    }
  end

  def test_verify_accepts_a_host_bound_message
    m = signed_message
    result = Solana::AuthVerifier.verify!(
      message: m[:message], signature_b58: m[:signature_b58], pubkey_b58: m[:pubkey_b58],
      expected_host: HOST, stored_nonce: m[:nonce]
    )
    assert_equal m[:pubkey_b58], result
  end

  # OPSEC-018: a signature over a message bound to a different host must be
  # rejected even when the nonce matches.
  def test_verify_rejects_host_mismatch
    m = signed_message
    err = assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message: m[:message], signature_b58: m[:signature_b58], pubkey_b58: m[:pubkey_b58],
        expected_host: "evil.example.com", stored_nonce: m[:nonce]
      )
    end
    assert_match(/not bound to host/, err.message)
  end

  def test_verify_requires_a_non_blank_expected_host
    m = signed_message
    assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message: m[:message], signature_b58: m[:signature_b58], pubkey_b58: m[:pubkey_b58],
        expected_host: "", stored_nonce: m[:nonce]
      )
    end
  end

  # The host match is exact — a host that is a prefix of the message's host
  # must not pass (the trailing space in the check guards against this).
  def test_verify_rejects_partial_host_prefix
    m = signed_message(host: "turf.example.com")
    assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(
        message: m[:message], signature_b58: m[:signature_b58], pubkey_b58: m[:pubkey_b58],
        expected_host: "turf.example", stored_nonce: m[:nonce]
      )
    end
  end
end

# Small-order and malformed keys/signatures that Ed25519::VerifyKey accepts.
# Every refusal below is preceded by a control proving the raw library accepts
# the same bytes — so each test fails if the strict checks are removed.
class AuthVerifierStrictTest < Minitest::Test
  include Ed25519ForgerySupport

  HOST = "turf.example.com"

  def sign_in_message(nonce)
    "#{HOST} wants to sign in with your Solana account:\n\nNonce: #{nonce}"
  end

  def verify(message:, signature:, public_key:, nonce:)
    Solana::AuthVerifier.verify!(
      message: message,
      signature_b58: Solana::Keypair.encode_base58(signature),
      pubkey_b58: Solana::Keypair.encode_base58(public_key),
      expected_host: HOST, stored_nonce: nonce
    )
  end

  def nonce_for(i) = "n#{i}x"

  def test_the_vector_table_is_self_consistent
    assert_equal 14, SMALL_ORDER_KEYS.size
    SMALL_ORDER_KEYS.each do |b58, hex|
      assert_equal hex_bytes(hex), Solana::Keypair.decode_base58(b58), "#{b58} decodes to its listed bytes"
      assert_equal b58, Solana::Keypair.encode_base58(hex_bytes(hex))
    end
  end

  def test_refuses_a_keyless_sign_in_for_every_small_order_encoding
    SMALL_ORDER_KEYS.each do |b58, hex|
      public_key = hex_bytes(hex)
      message, signature, i = grind(public_key,
                                    message_for: ->(n) { sign_in_message(nonce_for(n)) },
                                    signature_for: ->(_) { keyless_signature })

      err = assert_raises(Solana::AuthVerifier::VerificationError, "#{b58} must not sign in") do
        verify(message: message, signature: signature, public_key: public_key, nonce: nonce_for(i))
      end
      assert_match(/\APublic key is (a small-order|not a canonical encoding)/, err.message, b58)
    end
  end

  # PR #51 made this spelling decode to 32 bytes; before it, the length check
  # refused it by accident. It must be refused on purpose now.
  def test_refuses_the_all_ones_system_program_id
    b58 = "11111111111111111111111111111111"
    public_key = Solana::Keypair.decode_base58(b58)
    assert_equal 32, public_key.bytesize
    message, signature, i = grind(public_key,
                                  message_for: ->(n) { sign_in_message(nonce_for(n)) },
                                  signature_for: ->(_) { keyless_signature })

    err = assert_raises(Solana::AuthVerifier::VerificationError) do
      Solana::AuthVerifier.verify!(message: message, signature_b58: Solana::Keypair.encode_base58(signature),
                                   pubkey_b58: b58, expected_host: HOST, stored_nonce: nonce_for(i))
    end
    assert_match(/small-order/, err.message)
  end

  # A curve point with a torsion component is not small-order, but the library
  # still lets one secret key sign for it. It is refused by the subgroup check.
  def test_refuses_a_key_outside_the_prime_order_subgroup
    seed = ("\x07" * 32).b
    claimed = mixed_order_key(seed)
    assert_nil STRICT.public_key_problem(Solana::Keypair.new(Ed25519::SigningKey.new(seed)).public_key_bytes)
    refute STRICT.small_order?(STRICT.decode_point(claimed))

    message, signature, i = grind(claimed,
                                  message_for: ->(n) { sign_in_message(nonce_for(n)) },
                                  signature_for: ->(m) { sign_as(seed, claimed, m) })

    err = assert_raises(Solana::AuthVerifier::VerificationError) do
      verify(message: message, signature: signature, public_key: claimed, nonce: nonce_for(i))
    end
    assert_match(/\APublic key is not in the ed25519 prime-order subgroup/, err.message)
  end

  def test_refuses_a_small_order_r_even_from_the_real_key
    seed = ("\x2a" * 32).b
    public_key = Solana::Keypair.new(Ed25519::SigningKey.new(seed)).public_key_bytes
    message, signature, i = grind(public_key,
                                  message_for: ->(n) { sign_in_message(nonce_for(n)) },
                                  signature_for: ->(m) { sign_with_identity_r(seed, m) })

    err = assert_raises(Solana::AuthVerifier::VerificationError) do
      verify(message: message, signature: signature, public_key: public_key, nonce: nonce_for(i))
    end
    assert_match(/\ASignature R is a small-order/, err.message)
  end

  def test_refuses_an_unreduced_s
    kp = Solana::Keypair.new(Ed25519::SigningKey.new(("\x33" * 32).b))
    message, signature, i = grind(kp.public_key_bytes,
                                  message_for: ->(n) { sign_in_message(nonce_for(n)) },
                                  signature_for: ->(m) { unreduced(kp.sign(m)) || flunk("S + L overflowed three bits") })

    err = assert_raises(Solana::AuthVerifier::VerificationError) do
      verify(message: message, signature: signature, public_key: kp.public_key_bytes, nonce: nonce_for(i))
    end
    assert_match(/\ASignature S is not reduced/, err.message)
  end

  # The fix must not cost a real wallet its sign-in.
  def test_real_sign_ins_still_verify
    keypairs = Array.new(24) { Solana::Keypair.generate }
    keypairs << Solana::Keypair.new(Ed25519::SigningKey.new(("\x01" * 32).b))
    keypairs << Solana::Keypair.new(Ed25519::SigningKey.new(("\xff" * 32).b))

    keypairs.each_with_index do |kp, i|
      message = sign_in_message(nonce_for(i))
      result = Solana::AuthVerifier.verify!(
        message: message, signature_b58: Solana::Keypair.encode_base58(kp.sign(message)),
        pubkey_b58: kp.to_base58, expected_host: HOST, stored_nonce: nonce_for(i)
      )
      assert_equal kp.to_base58, result
    end
  end
end
