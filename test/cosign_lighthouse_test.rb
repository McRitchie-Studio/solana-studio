require_relative "cosign_support"

# Lighthouse, read by variant. Phantom inserts Lighthouse instructions into what
# it signs on mainnet, so the guard must admit them — but only the assertions.
# MemoryWrite (variant 0) makes a signer fund a memory account, and the fee payer
# signs every cosigned wire, so a wire that names it as payer would lock its SOL.
# See Cosign::LIGHTHOUSE_PROGRAM_ID for the variants and the mainnet evidence.
#
# Two directions, both pinned:
#   - every Lighthouse instruction Phantom actually sent in five cosigned mainnet
#     transactions is still ADMITTED, so narrowing the rule is caught; and
#   - MemoryWrite, MemoryClose, empty data and unknown variants are REFUSED
#     before the fee payer signs or any RPC call, so widening it is caught.
class CosignLighthouseTest < Minitest::Test
  include CosignSupport

  # Every distinct Lighthouse payload in the five mainnet transactions below,
  # decoded from `getTransaction` at `finalized` on 2026-09-16 (public chain
  # data). `info_*` are AssertAccountInfoMulti (variant 6), `token_*` are
  # AssertTokenAccountMulti (variant 10).
  PAYLOADS = {
    token_1: "0a04040300000600000000000000000501e1a9f7d96084158872de684a9ba9c5c6d2d95eedb766e4bab119db53f4d5bc2a0000c6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d6100",
    info_1: "06040203000001000000000000000000",
    info_2: "06040100000000000000000000",
    info_3: "06040102bad14677cb7e18cacfc2da6eb24e5dbd3cb2a1af95247a4a3f4a796f0d7d29f000",
    info_4: "06040303010001a500000000000000000851a365d091db74537db9d33fe38737777e127d89ae79cdf45eeba2a8b780af4600a501",
    info_5: "06040300bba7da07000000000403000001000000000000000000",
    token_2: "0a040402a8ea410900000000040300000600000000000000000508",
    info_6: "0604030025288d07000000000403000001000000000000000000",
    info_7: "06040303010001a50000000000000000081f2ba16a4a61c9fd5610bc3f11858a8292e47c5147828bef02c532d80e053e4d00a501",
    token_3: "0a04040228996b0600000000040300000600000000000000000508",
    info_8: "06040303010001a5000000000000000008c0cda08c2996a0df4aecebd5ed7dee6b7686b1411bbeb300105b0ef233361dbd00a501",
    token_4: "0a040402fae66b0800000000040300000600000000000000000508",
    info_9: "06040303010001a50000000000000000080cfcb0b58d6bad78c35ff0633d48d5ee8f6b37776ff1cf56252c4f45e4d73b5f00a501",
    token_5: "0a0404024ee8b20200000000040300000600000000000000000508"
  }.freeze

  # Each transaction's Lighthouse instructions, in wire order, split where the
  # app instruction sat: [before it, after it]. On chain every one reads
  # ComputeBudget, ComputeBudget, <before>, app instruction, <after>.
  WIRES = {
    "2Fv91MyXnJqsud6WoqN9btHPU6b3SpjK9t4dbwEUknjatLhzQk4PNWDvgxh2ei1foG6PUmaAwtMFtzgxPNYzpAdQ" =>
      [%i[token_1 info_1 info_2 info_3 info_4 info_1 info_3], %i[info_5 token_2]],
    "2QY6xTKEsQ7C16mtHA8injezmXGRAAZRbQk2BvncZSqwSCpD1eMdBpQvqQNyLv9fiDRKrfg2tZ3TEGkrwEr6PZqF" =>
      [%i[info_1 info_2 info_3 info_3 info_3 info_1], %i[info_6]],
    "XPNUqsyosPeuCRcekWujqYoCuaSkfyVhs8Ng9MsiMn4fGi7mXpP1zYQAuhhq4C5hqhqLkK5meSqVmzThVhBqttu" =>
      [%i[info_1 info_2 info_1 info_7 info_2], %i[info_5 token_3]],
    "64PSGgMSimKZjkGLiXMQGQMVC6GHGuZSVXSNEN3jdSoeeVQ2xz9erz9dzr1LwxE83Sxy43nmtyAAC5U8kiJxJhDr" =>
      [%i[info_8 info_2 info_1 info_1 info_2], %i[info_5 token_4]],
    "4MQki8ztuNyRFv2hQReNq5uRjFP1n8B4HtDZMZcp7T8XQucYYJy6KWbtjcMFctm8vReDCijvk7SkqQRY4f6hPG9B" =>
      [%i[info_1 info_9 info_1 info_2 info_2], %i[info_6 token_5]]
  }.freeze

  def setup
    @prepared = prepare
  end

  def expectation
    @prepared.expectation
  end

  def lighthouse(name)
    lighthouse_instruction(data: [PAYLOADS.fetch(name)].pack("H*"))
  end

  # Phantom's placement: ComputeBudget first, then Lighthouse around the app
  # instruction.
  def phantom_wire(before:, after:)
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(BLOCKHASH)
    tx.add_instruction(**Solana::ComputeBudget.set_compute_unit_price(PRICE))
    tx.add_instruction(**Solana::ComputeBudget.set_compute_unit_limit(LIMIT))
    before.each { |ix| tx.add_instruction(**ix) }
    tx.add_instruction(**app_instruction)
    after.each { |ix| tx.add_instruction(**ix) }
    tx.serialize_partial(additional_signers: [house.public_key_bytes, user.public_key_bytes])
  end

  # The exploit, in the layout the deployed program reads: MemoryWrite's
  # accounts are program, system program, PAYER (signer, writable), memory,
  # source; its data is memory_id u8, bump u8, write_offset (LEB128) and a
  # WriteType. Offset 10,000 plus AccountData { offset: 0, length: 8 } is a
  # 10,008-byte memory account. The payer is the fee payer, which already signs,
  # so the signer set is unchanged and only the variant rule can refuse it.
  def memory_write_paid_by_the_fee_payer(memory_id: 0)
    data = [0, memory_id, 255].pack("CCC") + [0x90, 0x4E].pack("CC") + [0].pack("C") + [0, 8].pack("vv")
    lighthouse_instruction(data: data, accounts: [
      { pubkey: LIGHTHOUSE, is_signer: false, is_writable: false },
      { pubkey: SYSTEM, is_signer: false, is_writable: false },
      { pubkey: house.public_key_bytes, is_signer: true, is_writable: true },
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: true },
      { pubkey: app_state, is_signer: false, is_writable: false }
    ])
  end

  def memory_close_paid_to_the_fee_payer
    lighthouse_instruction(data: [1, 0, 255].pack("CCC"), accounts: [
      { pubkey: LIGHTHOUSE, is_signer: false, is_writable: false },
      { pubkey: house.public_key_bytes, is_signer: true, is_writable: true },
      { pubkey: Solana::Keypair.generate.public_key_bytes, is_signer: false, is_writable: true }
    ])
  end

  # Refused through the completer, before the fee payer signs and with no RPC.
  def assert_rejected(reason, wire)
    calls_before = rpc.calls.size
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.cosign(b64(signed_by(wire, user)), expectation: expectation)
    end
    assert_equal reason.to_s, error.reason, error.message
    assert_equal calls_before, rpc.calls.size, "a refusal makes no RPC call"
    error
  end

  # ---- real mainnet Phantom wires still pass --------------------------------

  def test_the_fixture_is_every_lighthouse_instruction_of_the_five_wires
    all = WIRES.values.flatten
    assert_equal 37, all.size
    assert_equal 14, PAYLOADS.size
    assert_equal PAYLOADS.keys.sort, all.uniq.sort, "every payload is used, and only these"
    assert_equal({ 6 => 32, 10 => 5 }, all.map { |name| [PAYLOADS.fetch(name)].pack("H*").getbyte(0) }.tally)
  end

  def test_every_real_mainnet_phantom_wire_still_cosigns
    WIRES.each do |signature, (before, after)|
      wire = phantom_wire(before: before.map { |n| lighthouse(n) }, after: after.map { |n| lighthouse(n) })
      cosigned = completer.cosign(b64(signed_by(wire, user)), expectation: expectation)
      assert cosigned.message.signature_valid?(0), "the fee payer signed #{signature[0, 8]}'s instructions"
      assert_equal before.size + after.size + 3, cosigned.message.instructions.size
    end
  end

  def test_every_real_mainnet_phantom_wire_completes
    WIRES.each_value do |before, after|
      wire = phantom_wire(before: before.map { |n| lighthouse(n) }, after: after.map { |n| lighthouse(n) })
      result = completer.complete(b64(signed_by(wire, user)), expectation: expectation)
      assert_equal "confirmed", result.confirmation_status
    end
  end

  # ---- the rule, byte by byte -----------------------------------------------

  def test_only_variants_two_through_seventeen_are_admitted
    admitted = []
    refusals = {}
    (0..255).each do |variant|
      data = [variant].pack("C") + [PAYLOADS[:info_1]].pack("H*").byteslice(1..)
      msg = Solana::WireMessage.parse(phantom_wire(before: [], after: [lighthouse_instruction(data: data)]))
      begin
        expectation.verify!(msg)
        admitted << variant
      rescue Solana::Cosign::WireRejected => e
        refusals[variant] = e.reason
      end
    end

    assert_equal((2..17).to_a, admitted)
    assert_equal "lighthouse_memory_write", refusals[0]
    assert_equal "lighthouse_memory_close", refusals[1]
    assert_equal ["lighthouse_unknown_disc"], refusals.except(0, 1).values.uniq
    assert_equal 256 - 16 - 2, refusals.except(0, 1).size
  end

  # ---- refusals -------------------------------------------------------------

  def test_refuses_a_memory_write_that_makes_the_fee_payer_fund_a_memory_account
    error = assert_rejected(:lighthouse_memory_write, phantom_wire(before: [memory_write_paid_by_the_fee_payer], after: []))
    assert_match(/MemoryWrite/, error.message)
    assert_rejected(:lighthouse_memory_write, phantom_wire(before: [], after: [memory_write_paid_by_the_fee_payer]))
  end

  def test_refuses_a_memory_write_hidden_among_real_assertions
    before, after = WIRES.values.first
    wire = phantom_wire(before: before.map { |n| lighthouse(n) },
                        after: after.map { |n| lighthouse(n) } + [memory_write_paid_by_the_fee_payer(memory_id: 7)])
    error = assert_rejected(:lighthouse_memory_write, wire)
    assert_match(/ix #{2 + before.size + 1 + after.size} /, error.message, "the refusal names the instruction")
  end

  def test_complete_refuses_a_memory_write_before_any_rpc_call
    wire = phantom_wire(before: [lighthouse(:info_1)], after: [memory_write_paid_by_the_fee_payer])
    calls_before = rpc.call_names.dup
    error = assert_raises(Solana::Cosign::WireRejected) do
      completer.complete(b64(signed_by(wire, user)), expectation: expectation,
                         before_send: ->(_sig) { flunk "nothing may be recorded for a refused wire" })
    end
    assert_equal "lighthouse_memory_write", error.reason
    assert_equal calls_before, rpc.call_names, "no block height, simulation or send"
  end

  def test_refuses_a_memory_close
    assert_rejected(:lighthouse_memory_close, phantom_wire(before: [], after: [memory_close_paid_to_the_fee_payer]))
  end

  def test_refuses_an_empty_lighthouse_instruction
    error = assert_rejected(:lighthouse_empty_data, phantom_wire(before: [lighthouse_instruction(data: "")], after: []))
    assert_match(/no instruction variant/, error.message)
  end

  def test_refuses_an_unknown_variant
    [18, 99, 255].each do |variant|
      data = [variant].pack("C") + [PAYLOADS[:info_1]].pack("H*").byteslice(1..)
      error = assert_rejected(:lighthouse_unknown_disc, phantom_wire(before: [], after: [lighthouse_instruction(data: data)]))
      assert_match(/variant #{variant} /, error.message)
    end
  end

  # ---- only programs with a rule can be admitted ----------------------------

  def test_an_extra_program_needs_a_rule_that_reads_it
    memo = "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
    error = assert_raises(ArgumentError) do
      Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house, extra_programs: [LIGHTHOUSE, memo])
    end
    assert_match(/#{memo}.*no rule reads its instructions/, error.message)

    explicit = Solana::Cosign::Expectation.from_wire(@prepared.wire_base64, fee_payer: house,
                                                     extra_programs: [Solana::Cosign.base58(LIGHTHOUSE)])
    assert_equal [LIGHTHOUSE], explicit.extra_programs
    msg = Solana::WireMessage.parse(phantom_wire(before: [], after: [memory_write_paid_by_the_fee_payer]))
    assert_raises(Solana::Cosign::WireRejected) { explicit.verify!(msg) }
  end
end
