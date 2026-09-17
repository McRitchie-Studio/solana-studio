require_relative "cosign_support"

class WireMessageTest < Minitest::Test
  include CosignSupport

  def built_wire
    wallet_wire(before: [], after: [lighthouse_instruction])
  end

  def test_parses_what_transaction_serializes
    wire = built_wire
    msg = Solana::WireMessage.parse(wire)

    assert_equal 2, msg.num_required_signatures
    assert_equal house.public_key_bytes, msg.fee_payer
    assert_equal [house.public_key_bytes, user.public_key_bytes].sort, msg.signer_keys.sort
    assert_equal BLOCKHASH, msg.recent_blockhash_base58
    assert_equal 4, msg.instructions.size
    assert_equal [Solana::ComputeBudget::PROGRAM_ID, Solana::ComputeBudget::PROGRAM_ID, app_program, LIGHTHOUSE],
                 msg.instructions.map { |ix| ix[:program_id] }
    app = msg.instructions[2]
    assert_equal [user.public_key_bytes, app_state, SYSTEM], app[:accounts]
    assert_equal app_instruction[:data], app[:data]
    assert_equal wire, msg.to_bytes
  end

  def test_signer_and_writable_flags_follow_the_legacy_layout
    msg = Solana::WireMessage.parse(built_wire)
    assert msg.signer?(house.public_key_bytes)
    assert msg.signer?(user.public_key_bytes)
    refute msg.signer?(app_state)
    assert msg.writable?(0)
    assert msg.writable?(app_state)
    refute msg.writable?(app_program)
    refute msg.writable?(LIGHTHOUSE)
    refute msg.writable?("\x05".b * 32), "an absent key is not writable"
  end

  def test_a_readonly_signer_is_not_writable
    keys = [house.public_key_bytes, user.public_key_bytes, app_state, app_program]
    message = raw_message(header: [2, 1, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[3, [0, 1, 2], "x"]])
    msg = Solana::WireMessage.parse(raw_wire(message, 2))
    assert msg.writable?(0)
    refute msg.writable?(1), "the header's one read-only signer is the last signer"
    assert msg.writable?(2)
    refute msg.writable?(3)
  end

  def test_signature_is_the_first_slot_and_needs_it_filled
    wire = built_wire
    error = assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(wire).signature }
    assert_match(/fee-payer slot is empty/, error.message)

    signed = signed_by(wire, house)
    msg = Solana::WireMessage.parse(signed)
    assert_equal Solana::Keypair.encode_base58(signed.byteslice(1, 64)), msg.signature
  end

  def test_signature_valid_checks_key_slot_and_message
    wire = signed_by(built_wire, user)
    msg = Solana::WireMessage.parse(wire)
    user_slot = msg.account_keys.index(user.public_key_bytes)
    assert msg.signature_valid?(user_slot)
    refute msg.signature_valid?(0), "an empty slot is never valid"
    refute msg.signature_valid?(msg.account_keys.size - 1), "a non-signer index is never valid"

    # The same signature over a different message does not verify.
    tampered = wire.dup
    tampered.setbyte(tampered.bytesize - 1, tampered.getbyte(tampered.bytesize - 1) ^ 0xFF)
    refute Solana::WireMessage.parse(tampered).signature_valid?(user_slot)
  end

  def test_parse_base64_refuses_non_base64
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse_base64("not base64!!") }
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse_base64("") }
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse_base64(nil) }
  end

  def test_fails_closed_on_every_malformed_shape
    wire = built_wire
    cases = {
      "truncated signatures" => wire.byteslice(0, 40),
      "truncated message" => wire.byteslice(0, wire.bytesize - 3),
      "trailing bytes" => wire + "\x00".b,
      "zero signatures" => "\x00".b + wire.byteslice(1 + 128, wire.bytesize)
    }
    cases.each do |label, bytes|
      assert_raises(Solana::WireMessage::MalformedError, label) { Solana::WireMessage.parse(bytes) }
    end
  end

  def test_refuses_a_versioned_message
    keys = [house.public_key_bytes, app_program]
    message = raw_message(header: [1, 0, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[1, [0], "x"]])
    message.setbyte(0, 0x80 | 1)
    error = assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(message, 1)) }
    assert_match(/versioned/, error.message)
  end

  def test_refuses_header_signature_count_disagreeing_with_slots
    keys = [house.public_key_bytes, user.public_key_bytes, app_program]
    message = raw_message(header: [2, 0, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[2, [0, 1], "x"]])
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(message, 1)) }
  end

  def test_refuses_out_of_range_indices
    keys = [house.public_key_bytes, app_program]
    bad_program = raw_message(header: [1, 0, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[9, [0], "x"]])
    bad_account = raw_message(header: [1, 0, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[1, [0, 7], "x"]])
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(bad_program, 1)) }
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(bad_account, 1)) }
  end

  def test_refuses_a_duplicated_account_key
    # The runtime refuses a key loaded twice; a decoder that admitted one would
    # let a signer check and an instruction check read two different entries.
    keys = [house.public_key_bytes, app_program, app_program]
    message = raw_message(header: [1, 0, 2], keys: keys, blockhash: BLOCKHASH, instructions: [[1, [0], "x"]])
    error = assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(message, 1)) }
    assert_match(/duplicate/, error.message)
  end

  def test_refuses_readonly_counts_beyond_the_account_list
    keys = [house.public_key_bytes, app_program]
    message = raw_message(header: [1, 2, 1], keys: keys, blockhash: BLOCKHASH, instructions: [[1, [0], "x"]])
    assert_raises(Solana::WireMessage::MalformedError) { Solana::WireMessage.parse(raw_wire(message, 1)) }
  end
end
