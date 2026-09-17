require_relative "cosign_support"

# The guard. Every wire here is assembled independently of Cosign::Builder, as a
# wallet — or an attacker holding the user's key — would hand it back, and every
# refusal must happen before the house's key is used or any RPC is made.
class CosignExpectationTest < Minitest::Test
  include CosignSupport

  def setup
    @prepared = prepare
  end

  def expectation
    @prepared.expectation
  end

  # Judge a wallet wire the way the completer does, and prove the refusal
  # happened before the house signed or anything was sent.
  def assert_rejected(reason, wire)
    calls_before = rpc.calls.size
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(b64(signed_by(wire, user)), expectation: expectation)
    end
    assert_equal reason.to_s, error.reason, error.message
    assert_equal calls_before, rpc.calls.size, "a refusal makes no RPC call"
    error
  end

  def test_admits_the_wallet_re_encoding_with_lighthouse_inserted_anywhere
    wire = wallet_wire(before: [lighthouse_instruction], after: [lighthouse_instruction])
    msg = Solana::WireMessage.parse(signed_by(wire, user))
    refute_equal Base64.strict_decode64(@prepared.wire_base64), wire, "the bytes really differ from what was built"
    assert expectation.verify!(msg)
  end

  def test_admits_a_wallet_that_raises_the_price_within_the_cap
    msg = Solana::WireMessage.parse(signed_by(wallet_wire(price: PRICE * 10), user))
    assert expectation.verify!(msg)
  end

  def test_admits_a_permuted_account_list
    # A different encoder may order the non-signer keys differently. Meaning,
    # not position, is what is compared.
    keys = [house.public_key_bytes, user.public_key_bytes, app_state, SYSTEM, app_program,
            Solana::ComputeBudget::PROGRAM_ID]
    budget = [[5, [], Solana::ComputeBudget.set_compute_unit_price(PRICE)[:data]],
              [5, [], Solana::ComputeBudget.set_compute_unit_limit(LIMIT)[:data]]]
    message = raw_message(header: [2, 0, 3], keys: keys, blockhash: BLOCKHASH,
                          instructions: budget + [[4, [1, 2, 3], app_instruction[:data]]])
    wire = signed_by(raw_wire(message, 2), user)
    assert expectation.verify!(Solana::WireMessage.parse(wire))

    # Non-signers reordered, and the ComputeBudget pair split around the app
    # instruction. (app_state stays ahead of the three read-only keys the
    # header declares.)
    shuffled = [house.public_key_bytes, user.public_key_bytes, app_state, app_program,
                Solana::ComputeBudget::PROGRAM_ID, SYSTEM]
    message = raw_message(header: [2, 0, 3], keys: shuffled, blockhash: BLOCKHASH,
                          instructions: [[4, [], budget[1][2]], [3, [1, 2, 5], app_instruction[:data]],
                                         [4, [], budget[0][2]]])
    assert expectation.verify!(Solana::WireMessage.parse(signed_by(raw_wire(message, 2), user)))
  end

  def test_refuses_a_different_fee_payer
    attacker = Solana::Keypair.generate
    wire = wallet_wire(fee_payer: attacker.public_key_bytes, cosigners: [user.public_key_bytes, house.public_key_bytes])
    assert_rejected(:fee_payer_mismatch, wire)
  end

  def test_refuses_a_read_only_fee_payer
    # Both signers declared read-only: the keys and instructions all match, so
    # only the fee payer's writability can refuse it.
    keys = [house.public_key_bytes, user.public_key_bytes, app_state, SYSTEM, app_program,
            Solana::ComputeBudget::PROGRAM_ID]
    budget = [[5, [], Solana::ComputeBudget.set_compute_unit_price(PRICE)[:data]],
              [5, [], Solana::ComputeBudget.set_compute_unit_limit(LIMIT)[:data]]]
    message = raw_message(header: [2, 2, 3], keys: keys, blockhash: BLOCKHASH,
                          instructions: budget + [[4, [1, 2, 3], app_instruction[:data]]])
    assert_rejected(:fee_payer_not_writable, raw_wire(message, 2))
  end

  def test_refuses_a_system_transfer_draining_the_fee_payer
    drain = system_transfer_from(house.public_key_bytes, user.public_key_bytes, 5_000_000_000)
    error = assert_rejected(:unexpected_instruction, wallet_wire(after: [drain]))
    assert_match(/System/, error.message)
  end

  def test_refuses_a_nonce_advance_like_any_other_system_instruction
    advance = Solana::SystemProgram.advance_nonce_account(nonce: app_state, authority: house.public_key_bytes)
    assert_rejected(:unexpected_instruction, wallet_wire(before: [advance]))
  end

  def test_refuses_an_altered_amount
    assert_rejected(:instruction_data_mismatch, wallet_wire(instructions: [app_instruction(amount: 1)]))
  end

  def test_refuses_a_swapped_account
    other = Solana::Keypair.generate.public_key_bytes
    assert_rejected(:instruction_accounts_mismatch, wallet_wire(instructions: [app_instruction(state: other)]))
  end

  def test_refuses_a_duplicated_instruction
    assert_rejected(:unexpected_instruction, wallet_wire(instructions: [app_instruction, app_instruction]))
  end

  def test_refuses_a_missing_instruction
    assert_rejected(:instruction_missing, wallet_wire(instructions: [lighthouse_instruction]))
  end

  def test_refuses_an_unknown_program
    rogue = { program_id: Solana::Keypair.generate.public_key_bytes, accounts: [], data: "x".b }
    assert_rejected(:unexpected_instruction, wallet_wire(after: [rogue]))
  end

  def test_refuses_an_spl_token_instruction_nobody_built
    transfer = Solana::SplToken.transfer_instruction(from: app_state, to: app_state, authority: user.public_key_bytes, amount: 1)
    assert_rejected(:unexpected_instruction, wallet_wire(after: [transfer]))
  end

  def test_refuses_an_extra_signer_the_attacker_controls
    attacker = Solana::Keypair.generate
    ix = app_instruction.merge(accounts: app_instruction[:accounts] + [{ pubkey: attacker.public_key_bytes, is_signer: true }])
    wire = wallet_wire(instructions: [ix], cosigners: [user.public_key_bytes, attacker.public_key_bytes])
    calls_before = rpc.calls.size
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(b64(signed_by(wire, user, attacker)), expectation: expectation)
    end
    assert_equal "signer_set_mismatch", error.reason
    assert_match(/#{attacker.address}/, error.message)
    assert_equal calls_before, rpc.calls.size
  end

  def test_refuses_a_missing_cosigner
    ix = app_instruction.merge(accounts: app_instruction[:accounts].map { |a| a.merge(is_signer: false) })
    wire = wallet_wire(instructions: [ix], cosigners: [])
    error = assert_raises(Solana::Cosign::WireRejected) { completer.cosign(b64(wire), expectation: expectation) }
    assert_equal "signer_set_mismatch", error.reason
  end

  def test_refuses_a_price_over_the_cap
    assert_rejected(:compute_unit_price_over_cap, wallet_wire(price: (PRICE * 10) + 1))
  end

  def test_refuses_a_total_priority_fee_over_the_cap
    # Price within its cap, but the limit raised so price x limit is not.
    assert_rejected(:priority_fee_over_cap, wallet_wire(price: PRICE * 10, limit: (LIMIT * 1) + 1))
  end

  def test_a_price_with_no_limit_is_priced_at_the_runtime_maximum
    # With the limit: 100_000 x 200_000 = 2e10, under the 1e11 cap.
    assert expectation.verify!(Solana::WireMessage.parse(signed_by(wallet_wire(price: PRICE * 2), user)))
    # Without it the runtime maximum applies: 100_000 x 1_400_000 = 1.4e11, over.
    assert_rejected(:priority_fee_over_cap, wallet_wire(price: PRICE * 2, limit: nil))
  end

  def test_refuses_a_duplicated_or_unknown_compute_budget_instruction
    assert_rejected(:compute_budget_duplicate, wallet_wire(extra_compute: [Solana::ComputeBudget.set_compute_unit_price(1)]))
    heap = { program_id: Solana::ComputeBudget::PROGRAM_ID, accounts: [], data: [1].pack("C") + [65_536].pack("V") }
    assert_rejected(:compute_budget_not_allowed, wallet_wire(extra_compute: [heap]))
  end

  def test_blockhash_is_unpinned_by_default_and_refused_when_pinned
    moved = wallet_wire(blockhash: OTHER_BLOCKHASH)
    assert expectation.verify!(Solana::WireMessage.parse(signed_by(moved, user)))

    pinned = expectation.pinned_to(BLOCKHASH)
    error = assert_raises(Solana::Cosign::WireRejected) do
      pinned.verify!(Solana::WireMessage.parse(signed_by(moved, user)))
    end
    assert_equal "blockhash_mismatch", error.reason
    assert_nil expectation.blockhash, "pinning returns a copy"
  end

  def test_refuses_an_unparseable_wire
    error = assert_raises(Solana::Cosign::WireRejected) { completer.cosign("AAAA", expectation: expectation) }
    assert_equal "unparseable_wire", error.reason
  end

  def test_lighthouse_can_be_switched_off
    strict = Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house, extra_programs: [])
    wire = signed_by(wallet_wire(after: [lighthouse_instruction]), user)
    error = assert_raises(Solana::Cosign::WireRejected) { strict.verify!(Solana::WireMessage.parse(wire)) }
    assert_equal "unexpected_instruction", error.reason
  end

  def test_refuses_to_admit_a_fund_moving_program_as_extra
    [SYSTEM, Solana::Transaction::TOKEN_PROGRAM_ID, Solana::ComputeBudget::PROGRAM_ID,
     Solana::Transaction::ASSOCIATED_TOKEN_PROGRAM_ID, "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"].each do |program|
      assert_raises(ArgumentError) do
        Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house, extra_programs: [program])
      end
    end
  end

  def test_from_wire_rebuilds_the_same_expectation_the_builder_made
    rebuilt = Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house.address,
                                                    last_valid_block_height: @prepared.last_valid_block_height)
    %i[fee_payer cosigners instructions last_valid_block_height commitment max_compute_unit_price
       max_priority_fee_micro_lamports extra_programs].each do |field|
      assert_equal expectation.public_send(field), rebuilt.public_send(field), field.to_s
    end
    assert_nil rebuilt.blockhash, "unpinned unless asked"
    assert_equal Base64.strict_decode64(@prepared.wire_base64).byteslice(-1 * app_instruction[:data].bytesize, app_instruction[:data].bytesize),
                 rebuilt.instructions.first[:data]
  end

  def test_from_wire_can_pin_the_blockhash
    rebuilt = Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house, pin_blockhash: true)
    assert_equal Solana::Keypair.decode_base58(BLOCKHASH), rebuilt.blockhash
  end

  def test_from_wire_refuses_a_wire_with_another_fee_payer
    assert_raises(ArgumentError) do
      Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: Solana::Keypair.generate)
    end
  end

  def test_constructor_refuses_ambiguous_shapes
    base = { fee_payer: house, cosigners: [user], instructions: [app_instruction],
             max_compute_unit_price: 0, max_priority_fee_micro_lamports: 0 }
    assert_raises(ArgumentError) { Solana::Cosign::Expectation.new(**base, cosigners: [user, house]) }
    assert_raises(ArgumentError) { Solana::Cosign::Expectation.new(**base, cosigners: [user, user]) }
    assert_raises(ArgumentError) { Solana::Cosign::Expectation.new(**base, instructions: []) }
    assert_raises(ArgumentError) do
      Solana::Cosign::Expectation.new(**base, instructions: [Solana::ComputeBudget.set_compute_unit_price(1)])
    end
    assert_raises(ArgumentError) { Solana::Cosign::Expectation.new(**base, instructions: [lighthouse_instruction]) }
    assert_raises(ArgumentError) { Solana::Cosign::Expectation.new(**base, max_compute_unit_price: -1) }
  end
end
