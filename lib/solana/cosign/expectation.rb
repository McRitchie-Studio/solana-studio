module Solana
  module Cosign
    # What the server built, in the form a returned wire is judged against.
    #
    # A wallet re-encodes the wire and may insert its own protection
    # instructions, so the judgement is by MEANING, never by bytes:
    #
    #   1. Account 0 — the fee payer — is this server's fee payer, and writable.
    #   2. The signer set is EXACTLY the fee payer plus the named cosigners. No
    #      extra signer (an attacker's own key), none missing.
    #   3. Remove ComputeBudget instructions and instructions of an admitted
    #      extra program (Lighthouse by default). What remains must EQUAL the
    #      built instruction list: same programs, same ordered account keys, same
    #      data, same order. A generic library cannot know which of an app's
    #      accounts matter, so every one of them does. A System transfer from the
    #      fee payer, a nonce advance, a duplicated or swapped instruction, an
    #      altered amount — each fails here.
    #   4. ComputeBudget is READ, never waved through: only SetComputeUnitLimit
    #      and SetComputeUnitPrice, once each, and the fee they make the fee payer
    #      pay is capped (Cosign::DEFAULT_FEE_MARGIN).
    #   5. Optionally, the recent blockhash is the one built on (`blockhash:`).
    #      Off by default: turf-monster's production guards never pinned it, and
    #      whether any wallet rewrites it on mainnet has not been measured. Pin it
    #      when last_valid_block_height must describe the returned wire exactly.
    #
    # Writable flags other than the fee payer's are not compared: they cannot
    # move the fee payer's funds, and a wallet re-encoding them is not an attack
    # on the house.
    class Expectation
      # Programs an app may not admit as "extra": each can move lamports, tokens
      # or fees on its own, which is exactly what an admitted instruction is
      # trusted never to do.
      REFUSED_EXTRA_PROGRAMS = [
        Transaction::SYSTEM_PROGRAM_ID.b,
        ComputeBudget::PROGRAM_ID.b,
        Transaction::TOKEN_PROGRAM_ID.b,
        Keypair.decode_base58("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb").b,
        Transaction::ASSOCIATED_TOKEN_PROGRAM_ID.b
      ].freeze

      attr_reader :fee_payer, :cosigners, :instructions, :blockhash, :last_valid_block_height,
                  :commitment, :max_compute_unit_price, :max_priority_fee_micro_lamports, :extra_programs

      # instructions: [{ program_id:, accounts: [meta Hash or key], data: }] — the
      # same hashes Transaction#add_instruction takes. Account metas may carry
      # is_signer / is_writable; only the ordered keys are compared.
      def initialize(fee_payer:, cosigners:, instructions:, max_compute_unit_price:, max_priority_fee_micro_lamports:,
                     blockhash: nil, last_valid_block_height: nil, commitment: DEFAULT_COMMITMENT,
                     extra_programs: DEFAULT_EXTRA_PROGRAMS)
        @fee_payer = Cosign.key_bytes(fee_payer)
        @cosigners = Array(cosigners).map { |k| Cosign.key_bytes(k) }
        raise ArgumentError, "cosigners must be distinct" unless @cosigners.uniq.size == @cosigners.size
        raise ArgumentError, "the fee payer cannot also be a cosigner" if @cosigners.include?(@fee_payer)

        @extra_programs = Array(extra_programs).map { |k| Cosign.key_bytes(k) }.uniq
        refused = @extra_programs & REFUSED_EXTRA_PROGRAMS
        unless refused.empty?
          raise ArgumentError, "cannot admit #{refused.map { |k| Cosign.base58(k) }.join(', ')} as an extra program: " \
                               "it can move funds or fees on its own"
        end

        @instructions = Array(instructions).map { |ix| normalize_instruction(ix) }
        raise ArgumentError, "at least one instruction is required" if @instructions.empty?

        @instructions.each do |ix|
          if ix[:program_id] == ComputeBudget::PROGRAM_ID.b
            raise ArgumentError, "ComputeBudget is priced by the caps, not listed as an instruction"
          end
          if @extra_programs.include?(ix[:program_id])
            raise ArgumentError, "#{Cosign.base58(ix[:program_id])} is both a built instruction and an admitted extra program"
          end
        end

        @blockhash = blockhash.nil? ? nil : Cosign.key_bytes(blockhash)
        @last_valid_block_height = last_valid_block_height.nil? ? nil : Integer(last_valid_block_height)
        @commitment = commitment.to_s
        @max_compute_unit_price = non_negative!(max_compute_unit_price, "max_compute_unit_price")
        @max_priority_fee_micro_lamports = non_negative!(max_priority_fee_micro_lamports, "max_priority_fee_micro_lamports")
      end

      # Rebuild the expectation from a wire THIS SERVER BUILT and kept in its own
      # storage (a database row, never a request parameter), for the request that
      # receives the wallet's signature. The built wire's ComputeBudget pair
      # derives the fee caps; its signer slots after account 0 are the cosigners.
      #
      # A wire from the client is not a source of expectations — it is the thing
      # being judged. Passing one here judges the wire against itself.
      def self.from_wire(built_wire, fee_payer:, last_valid_block_height: nil, commitment: DEFAULT_COMMITMENT,
                         pin_blockhash: false, fee_margin: DEFAULT_FEE_MARGIN, extra_programs: DEFAULT_EXTRA_PROGRAMS,
                         encoding: :base64)
        message = WireMessage.parse_encoded(built_wire, encoding)
        payer = Cosign.key_bytes(fee_payer)
        unless message.fee_payer == payer
          raise ArgumentError, "the built wire's fee payer is #{Cosign.base58(message.fee_payer)}, not #{Cosign.base58(payer)}"
        end

        budget = {}
        instructions = []
        message.instructions.each do |ix|
          if ix[:program_id] == ComputeBudget::PROGRAM_ID.b
            kind, value = ComputeBudget.parse(ix[:data])
            raise ArgumentError, "the built wire repeats ComputeBudget #{kind}" if budget.key?(kind)

            budget[kind] = value
          else
            instructions << { program_id: ix[:program_id], accounts: ix[:accounts], data: ix[:data] }
          end
        end

        max_price, max_fee = Cosign.fee_caps(compute_unit_price: budget[:price], compute_unit_limit: budget[:limit],
                                             margin: fee_margin)
        new(
          fee_payer: payer,
          cosigners: message.signer_keys.drop(1),
          instructions: instructions,
          blockhash: pin_blockhash ? message.recent_blockhash : nil,
          last_valid_block_height: last_valid_block_height,
          commitment: commitment,
          max_compute_unit_price: max_price,
          max_priority_fee_micro_lamports: max_fee,
          extra_programs: extra_programs
        )
      end

      # The expectation with the recent blockhash pinned. See rule 5 above.
      def pinned_to(blockhash)
        dup.tap { |copy| copy.instance_variable_set(:@blockhash, Cosign.key_bytes(blockhash)) }
      end

      def signer_set
        [@fee_payer, *@cosigners]
      end

      # Judge a decoded wire. Returns true, or raises WireRejected naming the
      # first rule it breaks.
      def verify!(message)
        unless message.fee_payer == @fee_payer
          reject!(:fee_payer_mismatch, "account 0 is #{Cosign.base58(message.fee_payer)}, expected #{Cosign.base58(@fee_payer)}")
        end
        reject!(:fee_payer_not_writable, "account 0 is not writable") unless message.writable?(0)

        actual_signers = message.signer_keys
        extra = actual_signers - signer_set
        missing = signer_set - actual_signers
        unless extra.empty? && missing.empty?
          reject!(:signer_set_mismatch,
                  "unexpected signer(s) [#{extra.map { |k| Cosign.base58(k) }.join(', ')}], " \
                  "missing signer(s) [#{missing.map { |k| Cosign.base58(k) }.join(', ')}]")
        end

        if @blockhash && message.recent_blockhash != @blockhash
          reject!(:blockhash_mismatch, "wire anchors on #{message.recent_blockhash_base58}, built on #{Cosign.base58(@blockhash)}")
        end

        budget = {}
        observed = []
        message.instructions.each_with_index do |ix, index|
          if ix[:program_id] == ComputeBudget::PROGRAM_ID.b
            read_compute_budget!(ix, index, budget)
          elsif @extra_programs.include?(ix[:program_id])
            next
          else
            observed << ix.merge(index: index)
          end
        end

        compare_instructions!(observed)
        assert_fee_capped!(budget)
        true
      end

      private

      def normalize_instruction(ix)
        raise ArgumentError, "instruction must be a Hash with program_id:, accounts:, data:" unless ix.is_a?(Hash)

        data = ix.fetch(:data)
        {
          program_id: Cosign.key_bytes(ix.fetch(:program_id)),
          accounts: Array(ix.fetch(:accounts)).map { |a| Cosign.key_bytes(a.is_a?(Hash) ? a.fetch(:pubkey) : a) },
          data: data.is_a?(Array) ? data.pack("C*") : data.to_s.b
        }
      end

      def non_negative!(value, name)
        value = Integer(value)
        raise ArgumentError, "#{name} must be >= 0, got #{value}" if value.negative?

        value
      end

      def read_compute_budget!(ix, index, budget)
        kind, value =
          begin
            ComputeBudget.parse(ix[:data])
          rescue ArgumentError => e
            reject!(:compute_budget_not_allowed, "ix #{index}: #{e.message}")
          end
        reject!(:compute_budget_duplicate, "ix #{index} repeats #{kind}") if budget.key?(kind)
        budget[kind] = value
      end

      def compare_instructions!(observed)
        @instructions.each_with_index do |want, n|
          got = observed[n]
          reject!(:instruction_missing, "built instruction #{n} (#{Cosign.base58(want[:program_id])}) is absent") if got.nil?

          if got[:program_id] != want[:program_id]
            reject!(:unexpected_instruction,
                    "ix #{got[:index]} program #{program_label(got[:program_id])} where built instruction #{n} " \
                    "expects #{Cosign.base58(want[:program_id])}")
          end
          reject!(:instruction_data_mismatch, "ix #{got[:index]} data differs from built instruction #{n}") if got[:data] != want[:data]
          if got[:accounts] != want[:accounts]
            reject!(:instruction_accounts_mismatch,
                    "ix #{got[:index]} accounts [#{got[:accounts].map { |k| Cosign.base58(k) }.join(', ')}] differ from built instruction #{n}")
          end
        end

        return if observed.size == @instructions.size

        extra = observed[@instructions.size]
        reject!(:unexpected_instruction, "ix #{extra[:index]} program #{program_label(extra[:program_id])} was not built")
      end

      def assert_fee_capped!(budget)
        price = budget.fetch(:price, 0)
        if price > @max_compute_unit_price
          reject!(:compute_unit_price_over_cap, "#{price} > #{@max_compute_unit_price} micro-lamports/CU")
        end

        fee = ComputeBudget.priority_fee_micro_lamports(price: price, limit: budget[:limit])
        return if fee <= @max_priority_fee_micro_lamports

        reject!(:priority_fee_over_cap, "#{fee} > #{@max_priority_fee_micro_lamports} micro-lamports")
      end

      def program_label(program_id)
        program_id == Transaction::SYSTEM_PROGRAM_ID.b ? "System" : Cosign.base58(program_id)
      end

      def reject!(reason, detail)
        raise WireRejected.new(reason, detail)
      end
    end
  end
end
