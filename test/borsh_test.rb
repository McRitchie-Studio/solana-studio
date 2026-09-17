require_relative "test_helper"

class BorshTest < Minitest::Test
  def test_u8_roundtrip
    encoded = Solana::Borsh.encode_u8(42)
    value, offset = Solana::Borsh.decode_u8(encoded)
    assert_equal 42, value
    assert_equal 1, offset
  end

  def test_u16_roundtrip
    encoded = Solana::Borsh.encode_u16(1024)
    value, offset = Solana::Borsh.decode_u16(encoded)
    assert_equal 1024, value
    assert_equal 2, offset
  end

  def test_u32_roundtrip
    encoded = Solana::Borsh.encode_u32(100_000)
    value, offset = Solana::Borsh.decode_u32(encoded)
    assert_equal 100_000, value
    assert_equal 4, offset
  end

  def test_u64_roundtrip
    encoded = Solana::Borsh.encode_u64(10_000_000_000)
    value, offset = Solana::Borsh.decode_u64(encoded)
    assert_equal 10_000_000_000, value
    assert_equal 8, offset
  end

  def test_u64_max_value
    max = (2**64) - 1
    encoded = Solana::Borsh.encode_u64(max)
    value, _ = Solana::Borsh.decode_u64(encoded)
    assert_equal max, value
  end

  def test_string_encoding
    encoded = Solana::Borsh.encode_string("hello")
    # First 4 bytes = length (5), then "hello"
    length, offset = Solana::Borsh.decode_u32(encoded)
    assert_equal 5, length
    assert_equal "hello", encoded[offset, length]
  end

  def test_bool_encoding
    true_encoded = Solana::Borsh.encode_bool(true)
    false_encoded = Solana::Borsh.encode_bool(false)

    true_val, _ = Solana::Borsh.decode_u8(true_encoded)
    false_val, _ = Solana::Borsh.decode_u8(false_encoded)

    assert_equal 1, true_val
    assert_equal 0, false_val
  end

  def test_pubkey_encoding
    kp = Solana::Keypair.generate
    pubkey = kp.public_key_bytes

    encoded = Solana::Borsh.encode_pubkey(pubkey)
    assert_equal 32, encoded.bytesize
    decoded, offset = Solana::Borsh.decode_pubkey(encoded)
    assert_equal pubkey, decoded
    assert_equal 32, offset
  end

  def test_pubkey_from_base58_string
    kp = Solana::Keypair.generate
    address = kp.to_base58

    encoded = Solana::Borsh.encode_pubkey(address)
    assert_equal 32, encoded.bytesize
    assert_equal kp.public_key_bytes, encoded
  end

  # [integration] Keypair -> Borsh -> Transaction, in the exact shape turf-monster's
  # Solana::Vault#build_update_signers writes: an Anchor fixed-length [Pubkey; N]
  # whose empty tail is padded with the all-'1' zero address, each slot run through
  # decode_base58 and then encode_pubkey. Before fix-all-ones-base58-decode the
  # padding slot decoded to 33 bytes, encode_pubkey re-read that binary string as
  # base58, and the whole instruction raised `Invalid base58 character "\x00"`
  # (measured against the published 0.11.0 gem).
  def test_an_anchor_signer_array_padded_with_the_zero_address_encodes_32_bytes_per_slot
    zero_b58 = "1" * 32
    signers = Array.new(2) { Solana::Keypair.generate }
    padded = signers.map(&:address) + [zero_b58, zero_b58, zero_b58]

    data = Solana::Transaction.anchor_discriminator("update_signers") +
           padded.map { |key| Solana::Borsh.encode_pubkey(Solana::Keypair.decode_base58(key)) }.join

    assert_equal 8 + (32 * 5), data.bytesize
    slots = data.byteslice(8, 32 * 5).bytes.each_slice(32).map { |b| b.pack("C*") }
    assert_equal signers.map(&:public_key_bytes), slots.first(2)
    assert_equal [("\x00" * 32).b] * 3, slots.last(3)
  end

  def test_vec_encoding
    items = [1, 2, 3]
    encoded = Solana::Borsh.encode_vec(items) { |i| Solana::Borsh.encode_u32(i) }

    # First 4 bytes = count (3), then 3 x 4 bytes = 12 bytes of data
    count, offset = Solana::Borsh.decode_u32(encoded)
    assert_equal 3, count
    assert_equal 4 + 12, encoded.bytesize

    val1, offset = Solana::Borsh.decode_u32(encoded, offset)
    val2, offset = Solana::Borsh.decode_u32(encoded, offset)
    val3, _ = Solana::Borsh.decode_u32(encoded, offset)
    assert_equal [1, 2, 3], [val1, val2, val3]
  end

  def test_i64_encoding
    encoded = Solana::Borsh.encode_i64(-100)
    assert_equal 8, encoded.bytesize
  end

  def test_bytes32_encoding
    bytes = "\x00" * 32
    encoded = Solana::Borsh.encode_bytes32(bytes)
    assert_equal 32, encoded.bytesize
  end

  def test_bytes32_rejects_wrong_size
    assert_raises(RuntimeError) { Solana::Borsh.encode_bytes32("\x00" * 16) }
  end

  def test_decode_with_offset
    # Encode two u32 values back to back
    data = Solana::Borsh.encode_u32(42) + Solana::Borsh.encode_u32(99)

    val1, offset = Solana::Borsh.decode_u32(data, 0)
    val2, _ = Solana::Borsh.decode_u32(data, offset)

    assert_equal 42, val1
    assert_equal 99, val2
  end
end
