require_relative "test_helper"

class ComputeBudgetTest < Minitest::Test
  CB = Solana::ComputeBudget

  def test_program_id_is_the_compute_budget_program
    assert_equal "ComputeBudget111111111111111111111111111111", Solana::Keypair.encode_base58(CB::PROGRAM_ID)
  end

  # Byte-exact against @solana/web3.js ComputeBudgetProgram:
  #   setComputeUnitLimit({ units: 200000 })          => 02 400d0300
  #   setComputeUnitPrice({ microLamports: 50000 })   => 03 50c3000000000000
  def test_set_compute_unit_limit_encodes_u32_le
    ix = CB.set_compute_unit_limit(200_000)
    assert_equal "02400d0300", ix[:data].unpack1("H*")
    assert_equal CB::PROGRAM_ID, ix[:program_id]
    assert_empty ix[:accounts]
  end

  def test_set_compute_unit_price_encodes_u64_le
    ix = CB.set_compute_unit_price(50_000)
    assert_equal "0350c3000000000000", ix[:data].unpack1("H*")
  end

  def test_encoders_refuse_out_of_range_values
    assert_raises(ArgumentError) { CB.set_compute_unit_limit(0) }
    assert_raises(ArgumentError) { CB.set_compute_unit_limit(CB::MAX_COMPUTE_UNIT_LIMIT + 1) }
    assert_raises(ArgumentError) { CB.set_compute_unit_price(-1) }
  end

  def test_parse_round_trips_both_instructions
    assert_equal [:limit, 200_000], CB.parse(CB.set_compute_unit_limit(200_000)[:data])
    assert_equal [:price, 50_000], CB.parse(CB.set_compute_unit_price(50_000)[:data])
  end

  def test_parse_refuses_other_discriminators_and_wrong_lengths
    # RequestHeapFrame (1) and the deprecated RequestUnits (0) are not admitted.
    assert_raises(ArgumentError) { CB.parse([1].pack("C") + [4096].pack("V")) }
    assert_raises(ArgumentError) { CB.parse([0].pack("C") + [1, 2].pack("VV")) }
    # A padded or truncated field is not a shape any builder emits.
    assert_raises(ArgumentError) { CB.parse(CB.set_compute_unit_limit(5)[:data] + "\x00".b) }
    assert_raises(ArgumentError) { CB.parse(CB.set_compute_unit_price(5)[:data].byteslice(0, 8)) }
    assert_raises(ArgumentError) { CB.parse("".b) }
  end

  def test_priority_fee_prices_a_missing_limit_at_the_runtime_maximum
    assert_equal 50_000 * 200_000, CB.priority_fee_micro_lamports(price: 50_000, limit: 200_000)
    assert_equal 7 * CB::MAX_COMPUTE_UNIT_LIMIT, CB.priority_fee_micro_lamports(price: 7)
  end
end
