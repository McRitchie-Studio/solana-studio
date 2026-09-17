require_relative "test_helper"

class KeypairTest < Minitest::Test
  def test_generate_creates_valid_keypair
    kp = Solana::Keypair.generate
    assert_equal 32, kp.public_key_bytes.bytesize
    assert_equal 64, kp.to_bytes.bytesize
    assert kp.to_base58.length > 0
  end

  def test_base58_roundtrip
    kp = Solana::Keypair.generate
    address = kp.to_base58

    decoded = Solana::Keypair.decode_base58(address)
    re_encoded = Solana::Keypair.encode_base58(decoded)

    assert_equal address, re_encoded
  end

  def test_from_base58_secret_key_roundtrip
    kp = Solana::Keypair.generate
    secret_b58 = Solana::Keypair.encode_base58(kp.to_bytes)

    restored = Solana::Keypair.from_base58(secret_b58)
    assert_equal kp.to_base58, restored.to_base58
  end

  def test_from_bytes_array
    kp = Solana::Keypair.generate
    bytes_array = kp.to_bytes.bytes

    restored = Solana::Keypair.from_bytes(bytes_array)
    assert_equal kp.to_base58, restored.to_base58
  end

  def test_sign_produces_valid_signature
    kp = Solana::Keypair.generate
    message = "Hello Solana"

    signature = kp.sign(message)
    assert_equal 64, signature.bytesize

    # Verify signature using ed25519 gem
    assert kp.verify_key.verify(signature, message)
  end

  def test_address_alias
    kp = Solana::Keypair.generate
    assert_equal kp.to_base58, kp.address
  end

  def test_pubkey_from_base58
    kp = Solana::Keypair.generate
    address = kp.to_base58

    pubkey_bytes = Solana::Keypair.pubkey_from_base58(address)
    assert_equal 32, pubkey_bytes.bytesize
    assert_equal kp.public_key_bytes, pubkey_bytes
  end

  def test_decode_base58_preserves_leading_zeros
    # Base58 '1' represents a zero byte
    decoded = Solana::Keypair.decode_base58("1" * 5 + "2")
    assert_equal 0, decoded.bytes[0]
    assert_equal 0, decoded.bytes[1]
  end

  # REGRESSION (fix-all-ones-base58-decode): an input of only '1's has numeric
  # value zero, and the decoder used to emit a "00" body for that zero ON TOP of
  # one zero byte per leading '1' — so the System Program id decoded to 33 bytes,
  # which no 32-byte pubkey check accepts. Every all-'1' length was one byte long.
  def test_decode_base58_of_the_all_ones_system_program_is_32_zero_bytes
    decoded = Solana::Keypair.decode_base58("1" * 32)

    assert_equal 32, decoded.bytesize
    assert_equal ("\x00" * 32).b, decoded.b
  end

  def test_decode_base58_of_any_all_ones_input_is_one_zero_byte_per_character
    [1, 2, 5, 31, 32, 44].each do |length|
      assert_equal ("\x00" * length).b, Solana::Keypair.decode_base58("1" * length).b,
                   "#{length} '1's must decode to exactly #{length} zero bytes"
    end
  end

  def test_the_zero_key_round_trips_through_base58
    zero = ("\x00" * 32).b
    encoded = Solana::Keypair.encode_base58(zero)

    assert_equal "1" * 32, encoded
    assert_equal zero, Solana::Keypair.decode_base58(encoded).b
  end

  # The fix must not disturb a value that is NOT zero: leading '1's still add
  # exactly one zero byte each in front of the decoded body.
  def test_decode_base58_leading_ones_before_a_nonzero_body_are_unchanged
    assert_equal "\x00\x00\x01".b, Solana::Keypair.decode_base58("112").b

    kp = Solana::Keypair.generate
    assert_equal kp.public_key_bytes, Solana::Keypair.decode_base58(kp.to_base58)
  end

  def test_from_json_file
    kp = Solana::Keypair.generate
    tmpfile = "/tmp/test_keypair_#{Process.pid}.json"

    File.write(tmpfile, JSON.generate(kp.to_bytes.bytes))
    restored = Solana::Keypair.from_json_file(tmpfile)

    assert_equal kp.to_base58, restored.to_base58
  ensure
    File.delete(tmpfile) if File.exist?(tmpfile)
  end
end
