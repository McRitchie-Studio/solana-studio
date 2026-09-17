# frozen_string_literal: true

require_relative "test_helper"

# [unit] Solana::Cosign.key_bytes, the one normalizer every Cosign entry point
# runs a public key through (a Keypair, a base58 address, or 32 raw bytes).
#
# WHY THIS FILE EXISTS (fix-all-ones-base58-decode). key_bytes used to carry a
# special case for the all-'1' address, because Keypair.decode_base58 answered
# 33 bytes for it. Nothing pinned that case: a mutant deleting it SURVIVED, and
# without it the System Program id fell through to the raw-bytes branch and came
# back as 0x31 x 32 — a wrong key with no error. The decoder is fixed now and the
# special case is gone, so these tests hold the RESULT, whichever path produces it.
class CosignKeyBytesTest < Minitest::Test
  ZERO = ("\x00" * 32).b

  def test_the_all_ones_system_program_address_is_32_zero_bytes
    assert_equal ZERO, Solana::Cosign.key_bytes("1" * 32)
  end

  def test_the_all_ones_address_is_never_read_as_raw_ascii
    refute_equal ("1" * 32).b, Solana::Cosign.key_bytes("1" * 32),
                 "the System Program id came back as its own ASCII bytes (0x31 x 32)"
  end

  def test_it_agrees_with_the_transaction_system_program_constant
    assert_equal Solana::Transaction::SYSTEM_PROGRAM_ID.b, Solana::Cosign.key_bytes("11111111111111111111111111111111")
  end

  def test_a_base58_address_and_its_keypair_give_the_same_bytes
    kp = Solana::Keypair.generate

    assert_equal kp.public_key_bytes.b, Solana::Cosign.key_bytes(kp.address)
    assert_equal kp.public_key_bytes.b, Solana::Cosign.key_bytes(kp)
  end

  def test_32_binary_bytes_are_taken_as_raw
    assert_equal ZERO, Solana::Cosign.key_bytes(ZERO)
  end
end
