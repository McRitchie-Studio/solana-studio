require_relative "cosign_support"

class CosignBuilderTest < Minitest::Test
  include CosignSupport

  def test_build_returns_the_wire_and_its_deadline
    rpc.last_valid_block_height = 123_456
    prepared = prepare

    assert_equal BLOCKHASH, prepared.blockhash
    assert_equal 123_456, prepared.last_valid_block_height
    assert_equal "confirmed", prepared.commitment
    assert_equal house.address, prepared.fee_payer
    assert_equal [house.address, user.address], prepared.signers
    assert_equal 123_456, prepared.expectation.last_valid_block_height
    assert_equal [[:latest_blockhash, { commitment: "confirmed" }]], rpc.calls
  end

  def test_commitment_reaches_the_blockhash_fetch_and_the_expectation
    prepared = prepare(commitment: "finalized")
    assert_equal [[:latest_blockhash, { commitment: "finalized" }]], rpc.calls
    assert_equal "finalized", prepared.expectation.commitment
  end

  def test_fee_payer_is_account_zero_and_every_slot_is_empty
    msg = Solana::WireMessage.parse_base64(prepare.wire_base64)

    assert_equal house.public_key_bytes, msg.fee_payer
    assert msg.writable?(0)
    assert_equal 2, msg.num_required_signatures
    assert msg.signature_slot_empty?(0), "wallet-first: the house has not signed yet"
    assert msg.signature_slot_empty?(1)
    assert_equal BLOCKHASH, msg.recent_blockhash_base58
  end

  def test_compute_budget_pair_leads_and_app_instruction_follows_unchanged
    msg = Solana::WireMessage.parse_base64(prepare.wire_base64)
    programs = msg.instructions.map { |ix| ix[:program_id] }

    assert_equal [Solana::ComputeBudget::PROGRAM_ID, Solana::ComputeBudget::PROGRAM_ID, app_program], programs
    assert_equal [:price, PRICE], Solana::ComputeBudget.parse(msg.instructions[0][:data])
    assert_equal [:limit, LIMIT], Solana::ComputeBudget.parse(msg.instructions[1][:data])
    assert_equal app_instruction[:data], msg.instructions[2][:data]
    assert_equal [user.public_key_bytes, app_state, SYSTEM], msg.instructions[2][:accounts]
  end

  def test_no_compute_budget_means_zero_fee_caps
    prepared = builder.build(instructions: [app_instruction], cosigners: [user.public_key_bytes])
    programs = Solana::WireMessage.parse_base64(prepared.wire_base64).instructions.map { |ix| ix[:program_id] }

    assert_equal [app_program], programs
    assert_equal 0, prepared.expectation.max_compute_unit_price
    assert_equal 0, prepared.expectation.max_priority_fee_micro_lamports
  end

  def test_fee_caps_are_the_margin_times_the_builders_own_fee
    exp = prepare.expectation
    assert_equal PRICE * 10, exp.max_compute_unit_price
    assert_equal PRICE * LIMIT * 10, exp.max_priority_fee_micro_lamports

    exp = prepare(fee_margin: 2).expectation
    assert_equal PRICE * 2, exp.max_compute_unit_price
  end

  def test_presign_fills_only_the_fee_payer_slot_with_a_valid_signature
    msg = Solana::WireMessage.parse_base64(prepare(presign: true).wire_base64)

    assert_equal house.public_key_bytes, msg.fee_payer
    assert msg.signature_valid?(0), "the house signed the exact message bytes"
    assert msg.signature_slot_empty?(1), "the wallet's slot is still empty"
  end

  def test_presign_needs_a_keypair
    pubkey_only = Solana::Cosign::Builder.new(client: rpc, fee_payer: house.address)
    error = assert_raises(ArgumentError) do
      pubkey_only.build(instructions: [app_instruction], cosigners: [user.address], presign: true)
    end
    assert_match(/Keypair/, error.message)
    refute rpc.called?(:latest_blockhash), "refused before any RPC"
  end

  def test_a_public_key_is_enough_for_a_wallet_first_build
    pubkey_only = Solana::Cosign::Builder.new(client: rpc, fee_payer: house.address)
    prepared = pubkey_only.build(instructions: [app_instruction], cosigners: [user.address])
    assert_equal house.public_key_bytes, Solana::WireMessage.parse_base64(prepared.wire_base64).fee_payer
  end

  def test_keys_may_be_base58_including_the_all_ones_system_program
    ix = app_instruction
    ix = ix.merge(program_id: Solana::Keypair.encode_base58(app_program),
                  accounts: [{ pubkey: user.address, is_signer: true, is_writable: true },
                             { pubkey: Solana::Keypair.encode_base58(app_state), is_writable: true },
                             { pubkey: "11111111111111111111111111111111" }])
    msg = Solana::WireMessage.parse_base64(builder.build(instructions: [ix], cosigners: [user.address]).wire_base64)
    assert_equal [user.public_key_bytes, app_state, SYSTEM], msg.instructions.last[:accounts]
  end

  def test_refuses_a_signer_nobody_was_named_for
    stranger = Solana::Keypair.generate
    error = assert_raises(ArgumentError) do
      builder.build(instructions: [app_instruction(signer: stranger.public_key_bytes)], cosigners: [user.public_key_bytes])
    end
    assert_match(/#{stranger.address}/, error.message)
    refute rpc.called?(:latest_blockhash)
  end

  def test_refuses_the_fee_payer_as_a_cosigner_and_duplicate_cosigners
    assert_raises(ArgumentError) { builder.build(instructions: [app_instruction], cosigners: [user.address, house.address]) }
    assert_raises(ArgumentError) { builder.build(instructions: [app_instruction], cosigners: [user.address, user.address]) }
  end

  def test_refuses_compute_budget_passed_as_an_instruction
    assert_raises(ArgumentError) do
      builder.build(instructions: [Solana::ComputeBudget.set_compute_unit_price(1), app_instruction], cosigners: [user.address])
    end
  end

  def test_refuses_no_instructions
    assert_raises(ArgumentError) { builder.build(instructions: [], cosigners: [user.address]) }
  end

  def test_the_expectation_accepts_the_wire_it_was_built_with
    prepared = prepare
    msg = Solana::WireMessage.parse_base64(user_signed(prepared))
    assert prepared.expectation.verify!(msg)
  end
end
