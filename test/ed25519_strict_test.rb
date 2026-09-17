require_relative "test_helper"
require_relative "ed25519_forgery_support"

# Solana::Ed25519Strict on its own: the point arithmetic agrees with the ed25519
# gem, every small-order spelling is refused for the reason it deserves, and a
# real signature still verifies.
class Ed25519StrictTest < Minitest::Test
  include Ed25519ForgerySupport

  def keypair(seed)
    Solana::Keypair.new(Ed25519::SigningKey.new(seed.b))
  end

  # The arithmetic is only worth trusting if [a]B lands on the public key the
  # library derives from the same seed.
  def test_scalar_multiplication_agrees_with_the_library
    seeds = [("\x00" * 32), ("\x01" * 32), ("\xff" * 32)] + Array.new(5) { Random.bytes(32) }
    seeds.each do |seed|
      expected = keypair(seed).public_key_bytes
      assert_equal expected, STRICT.encode_point(STRICT.scalar_mult(clamped_scalar(seed), BASE_POINT))
      assert_equal expected, STRICT.encode_point(STRICT.decode_point(expected)), "decode/encode round trip"
    end
  end

  def test_base_point_has_prime_order
    refute STRICT.small_order?(BASE_POINT)
    assert STRICT.in_prime_order_subgroup?(BASE_POINT)
    refute STRICT.identity?(STRICT.scalar_mult(STRICT::L - 1, BASE_POINT))
  end

  def test_generated_keys_are_valid
    20.times do
      key = Solana::Keypair.generate.public_key_bytes
      assert_nil STRICT.public_key_problem(key), Solana::Keypair.encode_base58(key)
    end
  end

  def test_canonical_small_order_encodings_decode_and_are_refused_as_small_order
    SMALL_ORDER_CANONICAL.each do |b58, hex|
      point = STRICT.decode_point(hex_bytes(hex))
      refute_nil point, "#{b58} is a canonical encoding"
      assert STRICT.small_order?(point), b58
      assert_equal "is a small-order ed25519 point", STRICT.public_key_problem(hex_bytes(hex))
    end
  end

  # The identity passes [L]P == identity (so does nothing else small-order):
  # the small-order check has to run first, and has to be there at all.
  def test_the_identity_is_in_the_subgroup_so_small_order_must_be_checked
    assert STRICT.in_prime_order_subgroup?(STRICT::IDENTITY)
    assert STRICT.small_order?(STRICT::IDENTITY)
    refute STRICT.valid_public_key?(STRICT.encode_point(STRICT::IDENTITY))
  end

  def test_non_canonical_aliases_do_not_decode
    SMALL_ORDER_ALIASES.each do |b58, hex|
      assert_nil STRICT.decode_point(hex_bytes(hex)), b58
      assert_equal "is not a canonical encoding of an ed25519 point", STRICT.public_key_problem(hex_bytes(hex))
    end
  end

  def test_a_point_off_the_curve_does_not_decode
    off_curve = (2..200).map { |y| le_bytes(y) }.find { |bytes| STRICT.decode_point(bytes).nil? }
    refute_nil off_curve
    assert_equal "is not a canonical encoding of an ed25519 point", STRICT.public_key_problem(off_curve)
  end

  def test_mixed_order_key_is_refused_by_the_subgroup_check
    claimed = mixed_order_key(("\x07" * 32).b)
    assert_equal "is not in the ed25519 prime-order subgroup", STRICT.public_key_problem(claimed)
  end

  def test_verify_accepts_a_real_signature_and_refuses_a_tampered_one
    kp = keypair("\x05" * 32)
    signature = kp.sign("hello")
    assert STRICT.verify(kp.public_key_bytes, signature, "hello")
    refute STRICT.verify(kp.public_key_bytes, signature, "hellO")
  end

  # Two keyless signatures per key. The second has a prime-order R and a reduced
  # S, so it passes signature_problem: only the key check can refuse it.
  def test_verify_refuses_every_small_order_key_the_library_accepts
    prime_r = STRICT.encode_point(STRICT.scalar_mult(12_345, BASE_POINT)) + le_bytes(12_345)
    assert_nil STRICT.signature_problem(prime_r)
    SMALL_ORDER_KEYS.each do |b58, hex|
      key = hex_bytes(hex)
      [keyless_signature, prime_r].each do |candidate|
        message, signature, = grind(key, message_for: ->(n) { "m#{n}" }, signature_for: ->(_) { candidate })
        refute STRICT.verify(key, signature, message), b58
      end
    end
  end

  def test_verify_refuses_small_order_r_and_unreduced_s_that_the_library_accepts
    seed = ("\x2a" * 32).b
    key = keypair(seed).public_key_bytes

    message, signature, = grind(key, message_for: ->(n) { "r#{n}" }, signature_for: ->(m) { sign_with_identity_r(seed, m) })
    refute STRICT.verify(key, signature, message)
    assert_equal "R is a small-order ed25519 point", STRICT.signature_problem(signature)

    message, signature, = grind(key, message_for: ->(n) { "s#{n}" }, signature_for: ->(m) { unreduced(keypair(seed).sign(m)) })
    refute STRICT.verify(key, signature, message)
    assert_equal "S is not reduced below the group order", STRICT.signature_problem(signature)

    # The boundary is strict, as the cluster's is: S = L is refused, L - 1 is not.
    assert_equal "S is not reduced below the group order", STRICT.signature_problem(signature.byteslice(0, 32) + le_bytes(L))
    assert_nil STRICT.signature_problem(signature.byteslice(0, 32) + le_bytes(L - 1))
  end

  def test_malformed_input_is_refused_without_raising
    kp = keypair("\x09" * 32)
    signature = kp.sign("m")
    refute STRICT.verify(kp.public_key_bytes.byteslice(0, 31), signature, "m")
    refute STRICT.verify(kp.public_key_bytes, signature.byteslice(0, 63), "m")
    refute STRICT.verify(nil, nil, "m")
    assert_equal "must be 32 bytes, got 31", STRICT.public_key_problem(kp.public_key_bytes.byteslice(0, 31))
    assert_equal "must be 64 bytes, got 0", STRICT.signature_problem(nil)
  end
end
