require_relative "cosign_support"

class CosignCompleterTest < Minitest::Test
  include CosignSupport

  def setup
    @prepared = prepare
    @signed = user_signed(@prepared)
  end

  def complete(**opts)
    completer.complete(@signed, expectation: @prepared.expectation, **opts)
  end

  # ---- cosign (no RPC) --------------------------------------------------------

  def test_cosign_fills_the_house_slot_and_leaves_the_wallet_signature_untouched
    result = completer.cosign(@signed, expectation: @prepared.expectation)
    before = Solana::WireMessage.parse_base64(@signed)
    after = Solana::WireMessage.parse_base64(result.wire_base64)

    assert after.signature_valid?(0), "house signature verifies"
    assert after.signature_valid?(1), "wallet signature still verifies"
    assert_equal before.signatures[1], after.signatures[1]
    assert_equal before.message_bytes, after.message_bytes
    assert_equal after.signature, result.signature
    assert_empty rpc.calls.drop(1), "cosign makes no RPC call (the one call is the build's blockhash)"
  end

  def test_cosign_refuses_an_unsigned_cosigner_slot_before_the_house_signs
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(@prepared.wire_base64, expectation: @prepared.expectation)
    end
    assert_equal "signature_missing", error.reason
    assert_match(/#{user.address}/, error.message)
  end

  def test_cosign_refuses_a_forged_cosigner_signature
    wire = Base64.strict_decode64(@signed)
    slot = Solana::WireMessage.parse(wire).account_keys.index(user.public_key_bytes)
    offset = 1 + (slot * 64)
    wire[offset, 64] = Solana::Keypair.generate.sign("something else")
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(b64(wire), expectation: @prepared.expectation)
    end
    assert_equal "signature_invalid", error.reason
  end

  def test_cosign_accepts_a_presigned_wire_whose_message_is_unchanged
    prepared = prepare(presign: true)
    result = completer.cosign(user_signed(prepared), expectation: prepared.expectation)
    msg = Solana::WireMessage.parse_base64(result.wire_base64)
    assert msg.signature_valid?(0)
    assert msg.signature_valid?(1)
  end

  def test_cosign_refuses_a_presigned_wire_the_wallet_modified
    prepared = prepare(presign: true)
    presigned = Solana::WireMessage.parse_base64(prepared.wire_base64)
    # The wallet inserts Lighthouse and re-encodes, keeping the house's old signature.
    modified = wallet_wire(after: [lighthouse_instruction])
    modified[1, 64] = presigned.signatures[0]
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(b64(signed_by(modified, user)), expectation: prepared.expectation)
    end
    assert_equal "fee_payer_signature_invalid", error.reason
  end

  def test_completer_needs_a_keypair_and_the_matching_expectation
    assert_raises(ArgumentError) { Solana::Cosign::Completer.new(client: rpc, fee_payer: house.address) }

    other = Solana::Cosign::Completer.new(client: rpc, fee_payer: Solana::Keypair.generate, sleeper: ->(_) {})
    assert_raises(ArgumentError) { other.cosign(@signed, expectation: @prepared.expectation) }
  end

  # ---- complete: the happy path ---------------------------------------------

  def test_complete_checks_simulates_records_sends_and_confirms_in_that_order
    recorded = nil
    result = complete(before_send: ->(sig) { recorded = [sig, rpc.call_names.dup] })

    assert_equal %i[latest_blockhash get_block_height simulate_transaction send_transaction confirm_transaction],
                 rpc.call_names
    assert_equal result.signature, recorded[0]
    refute_includes recorded[1], :send_transaction, "the signature is handed over BEFORE the send"
    assert_equal "confirmed", result.confirmation_status

    sent = Solana::WireMessage.parse_base64(result.wire_base64)
    assert sent.signature_valid?(0)
    assert sent.signature_valid?(1)
    assert_equal sent.signature, result.signature
  end

  def test_the_build_commitment_rides_all_the_way_to_the_send
    prepared = prepare(commitment: "finalized")
    rpc.statuses = [{ "err" => nil, "confirmationStatus" => "finalized" }]
    completer.complete(user_signed(prepared), expectation: prepared.expectation)

    height = rpc.calls.find { |name, _| name == :get_block_height }[1]
    sim = rpc.calls.find { |name, _| name == :simulate_transaction }[1]
    send = rpc.calls.find { |name, _| name == :send_transaction }[1]
    assert_equal "finalized", height[:commitment]
    assert_equal "finalized", sim[:commitment]
    assert_equal "finalized", send[:preflight_commitment]
  end

  def test_simulation_judges_the_program_not_the_signatures_or_blockhash
    complete
    sim = rpc.calls.find { |name, _| name == :simulate_transaction }[1]
    assert_equal false, sim[:sig_verify]
    assert_equal true, sim[:replace_recent_blockhash]
    assert Solana::WireMessage.parse_base64(sim[:wire]).signature_valid?(0), "the simulated wire is the cosigned one"
  end

  def test_waits_through_processed_until_the_commitment_is_reached
    rpc.statuses = [nil, { "err" => nil, "confirmationStatus" => "processed" },
                    { "err" => nil, "confirmationStatus" => "confirmed" }]
    assert_equal "confirmed", complete.confirmation_status
    assert_equal 3, rpc.call_names.count(:confirm_transaction)
  end

  def test_a_failed_status_read_is_not_a_verdict
    rpc.statuses = [Solana::Client::RpcError.new("429"), { "err" => nil, "confirmationStatus" => "confirmed" }]
    assert_equal "confirmed", complete.confirmation_status
  end

  def test_confirm_timeout_nil_returns_after_the_send
    result = complete(confirm_timeout: nil)
    assert_nil result.confirmation_status
    refute rpc.called?(:confirm_transaction)
  end

  def test_simulate_false_skips_the_simulation
    complete(simulate: false)
    refute rpc.called?(:simulate_transaction)
  end

  def test_no_deadline_known_means_no_height_check
    expectation = Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house)
    completer.complete(@signed, expectation: expectation)
    refute rpc.called?(:get_block_height)
  end

  # ---- provably never sent ---------------------------------------------------

  def test_an_expired_blockhash_is_typed_and_nothing_is_sent
    rpc.block_heights = [@prepared.last_valid_block_height + 1]
    recorded = false
    error = assert_raises(Solana::Cosign::BlockhashExpired) { complete(before_send: ->(_) { recorded = true }) }

    assert_kind_of Solana::Cosign::PreflightRejected, error
    assert_equal @prepared.last_valid_block_height + 1, error.block_height
    assert_equal @prepared.last_valid_block_height, error.last_valid_block_height
    refute_nil error.signature
    refute recorded, "before_send never runs for a transaction that will not be sent"
    refute rpc.called?(:simulate_transaction)
    refute rpc.called?(:send_transaction)
  end

  def test_the_last_valid_height_itself_is_still_valid
    rpc.block_heights = [@prepared.last_valid_block_height]
    assert complete.signature
  end

  def test_an_unreadable_block_height_is_a_preflight_rejection
    rpc.block_heights = [Solana::Client::RpcError.new("rpc down")]
    error = assert_raises(Solana::Cosign::PreflightRejected) { complete }
    refute_kind_of Solana::Cosign::BlockhashExpired, error
    refute rpc.called?(:send_transaction)
  end

  def test_a_program_refusal_is_typed_with_its_logs_and_nothing_is_sent
    rpc.simulation = { "err" => { "InstructionError" => [2, { "Custom" => 6001 }] },
                       "logs" => ["Program log: AnchorError", "custom program error: 0x1771"] }
    error = assert_raises(Solana::Cosign::SimulationFailed) { complete }

    assert_kind_of Solana::Cosign::PreflightRejected, error
    assert_equal({ "InstructionError" => [2, { "Custom" => 6001 }] }, error.err)
    assert_includes error.logs, "custom program error: 0x1771"
    refute rpc.called?(:send_transaction)
  end

  def test_a_simulation_that_cannot_run_is_a_preflight_rejection
    rpc.simulation = Solana::Client::RpcError.new("rate limited", code: 429)
    assert_raises(Solana::Cosign::PreflightRejected) { complete }
    refute rpc.called?(:send_transaction)
  end

  def test_before_send_raising_stops_the_send_and_propagates_unchanged
    claim_lost = Class.new(StandardError)
    assert_raises(claim_lost) { complete(before_send: ->(_) { raise claim_lost, "row already claimed" }) }
    refute rpc.called?(:send_transaction)
  end

  # ---- may be on chain -------------------------------------------------------

  def test_a_blockhash_not_found_at_send_is_broadcast_expired_not_preflight
    rpc.send_result = Solana::Client::RpcError.new("Transaction simulation failed: Blockhash not found", code: -32_002)
    error = assert_raises(Solana::Cosign::BroadcastExpired) { complete }

    assert_kind_of Solana::Cosign::BroadcastFailed, error
    refute_kind_of Solana::Cosign::PreflightRejected, error,
                   "a send-time answer never licenses a silent rebuild: Client#call may have re-posted the wire"
    assert_equal Solana::WireMessage.parse_base64(rpc.calls.find { |n, _| n == :send_transaction }[1][:wire]).signature,
                 error.signature
  end

  def test_any_other_send_failure_is_broadcast_failed_with_the_signature
    rpc.send_result = Solana::Client::RpcError.new("Network error: execution expired")
    error = assert_raises(Solana::Cosign::BroadcastFailed) { complete }
    refute_kind_of Solana::Cosign::BroadcastExpired, error
    refute_nil error.signature
  end

  def test_a_node_signature_that_disagrees_with_the_wire_is_refused
    rpc.send_result = "1111111111111111111111111111111111111111111111111111111111111111"
    error = assert_raises(Solana::Cosign::BroadcastFailed) { complete }
    assert_match(/reconcile both/, error.message)
    refute rpc.called?(:confirm_transaction)
  end

  def test_landed_and_failed_is_transaction_failed
    rpc.statuses = [{ "err" => { "InstructionError" => [0, "InvalidAccountData"] }, "confirmationStatus" => "confirmed" }]
    error = assert_raises(Solana::Cosign::TransactionFailed) { complete }
    refute_kind_of Solana::Cosign::BroadcastFailed, error
    assert_equal({ "InstructionError" => [0, "InvalidAccountData"] }, error.err)
    refute_nil error.signature
  end

  def test_no_status_after_the_deadline_height_is_broadcast_expired
    rpc.statuses = [nil]
    rpc.block_heights = [900, @prepared.last_valid_block_height + 5]
    error = assert_raises(Solana::Cosign::BroadcastExpired) { complete }
    refute_nil error.signature
  end

  def test_confirmation_timeout_is_broadcast_failed
    rpc.statuses = [nil]
    now = 0.0
    clock = -> { now += 20.0 }
    slow = Solana::Cosign::Completer.new(client: rpc, fee_payer: house, sleeper: ->(_) {}, clock: clock)
    error = assert_raises(Solana::Cosign::BroadcastFailed) do
      slow.complete(@signed, expectation: @prepared.expectation, confirm_timeout: 30)
    end
    refute_kind_of Solana::Cosign::BroadcastExpired, error
    assert_match(/timed out/, error.message)
  end

  def test_a_refused_wire_never_reaches_the_network
    tampered = b64(signed_by(wallet_wire(instructions: [app_instruction(amount: 1)]), user))
    calls = rpc.calls.size
    assert_raises(Solana::Cosign::WireRejected) do
      completer.complete(tampered, expectation: @prepared.expectation, before_send: ->(_) { flunk "recorded" })
    end
    assert_equal calls, rpc.calls.size
  end
end
