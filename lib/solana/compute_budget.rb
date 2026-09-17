module Solana
  # ComputeBudget program instruction encoders — the priority-fee pair every
  # house-paid transaction needs, plus the reader a cosign guard uses to price
  # what a wallet handed back.
  #
  # WHY THESE BELONG IN THE GEM. A fee-less transaction lands on an empty devnet
  # and is dropped by a loaded mainnet leader (turf-monster lost two contest
  # creates that way on 2026-06-02). Every app that pays fees for its users needs
  # the same two instructions, and every app that cosigns a wallet-returned wire
  # needs to READ them, because the fee payer pays price x limit whether the
  # transaction then succeeds or fails.
  #
  # Each encoder returns a { program_id:, accounts:, data: } hash for
  # Transaction#add_instruction, the same shape SplToken and SystemProgram use.
  module ComputeBudget
    module_function

    PROGRAM_ID = Keypair.decode_base58("ComputeBudget111111111111111111111111111111")

    # Discriminators (first data byte). Only these two are ever built or admitted
    # by Solana::Cosign; RequestHeapFrame (1) and the deprecated RequestUnits (0)
    # are shapes no house-paid builder asks for.
    SET_COMPUTE_UNIT_LIMIT = 0x02 # followed by u32 LE units
    SET_COMPUTE_UNIT_PRICE = 0x03 # followed by u64 LE micro-lamports per CU

    # The runtime's ceiling. A wire that sets a price but no limit is charged at
    # whatever limit the runtime applies, so a fee check assumes this — it may
    # over-estimate, never under-.
    MAX_COMPUTE_UNIT_LIMIT = 1_400_000

    MICRO_LAMPORTS_PER_LAMPORT = 1_000_000

    def set_compute_unit_limit(units)
      units = Integer(units)
      raise ArgumentError, "compute unit limit must be 1..#{MAX_COMPUTE_UNIT_LIMIT}, got #{units}" unless units.between?(1, MAX_COMPUTE_UNIT_LIMIT)

      { program_id: PROGRAM_ID, accounts: [], data: [SET_COMPUTE_UNIT_LIMIT].pack("C") + [units].pack("V") }
    end

    def set_compute_unit_price(micro_lamports)
      micro_lamports = Integer(micro_lamports)
      raise ArgumentError, "compute unit price must be >= 0, got #{micro_lamports}" if micro_lamports.negative?

      { program_id: PROGRAM_ID, accounts: [], data: [SET_COMPUTE_UNIT_PRICE].pack("C") + [micro_lamports].pack("Q<") }
    end

    # Decode one ComputeBudget instruction's data. Returns [:limit, units] or
    # [:price, micro_lamports]; raises ArgumentError for any other discriminator
    # or a length that is not the exact encoded size (a padded or truncated
    # field is a shape no builder emits).
    def parse(data)
      data = data.to_s.b
      case data.getbyte(0)
      when SET_COMPUTE_UNIT_LIMIT
        raise ArgumentError, "SetComputeUnitLimit must be 5 bytes, got #{data.bytesize}" unless data.bytesize == 5

        [:limit, data.byteslice(1, 4).unpack1("V")]
      when SET_COMPUTE_UNIT_PRICE
        raise ArgumentError, "SetComputeUnitPrice must be 9 bytes, got #{data.bytesize}" unless data.bytesize == 9

        [:price, data.byteslice(1, 8).unpack1("Q<")]
      else
        raise ArgumentError, "unsupported ComputeBudget instruction discriminator #{data.byteslice(0, 1).to_s.unpack1('H*').inspect}"
      end
    end

    # The priority fee, in micro-lamports, a fee payer is charged for this
    # price and limit. A nil limit is priced at the runtime maximum.
    def priority_fee_micro_lamports(price:, limit: nil)
      Integer(price) * Integer(limit || MAX_COMPUTE_UNIT_LIMIT)
    end
  end
end
