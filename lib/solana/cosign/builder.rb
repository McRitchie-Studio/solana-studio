module Solana
  module Cosign
    # A built transaction, ready for its cosigners, with the deadline attached.
    #
    #   wire_base64              the wire to hand the wallet(s); #wire_base58 too
    #   blockhash                the recent blockhash it is anchored on (base58)
    #   last_valid_block_height  once the cluster's block height passes this, the
    #                            transaction can never land — rebuild BEFORE
    #                            prompting if the remainder is short
    #   commitment               what the blockhash was fetched at; send at the same
    #   fee_payer                base58
    #   signers                  base58, in signature-slot order (fee payer first)
    #   expectation              what Completer judges the returned wire against
    #
    # Store wire_base64 and last_valid_block_height server-side if the signature
    # comes back in a later request; Expectation.from_wire rebuilds the rest.
    Prepared = Struct.new(:wire_base64, :blockhash, :last_valid_block_height, :commitment,
                          :fee_payer, :signers, :expectation, keyword_init: true) do
      # The same wire in base58, the format SolanaStudio.walletOps `prepare`
      # returns to the browser — no conversion in host JavaScript.
      def wire_base58
        Keypair.encode_base58(Base64.strict_decode64(wire_base64))
      end
    end

    # Builds a transaction the SERVER pays for.
    #
    # The fee payer is account 0 and every named cosigner gets an empty slot. By
    # default the fee payer's slot is empty too (WALLET-FIRST): the wallet signs
    # an unsigned transaction, and the server fills its own slot afterwards. That
    # is the order Phantom does not flag. When the server signs first and the
    # wallet second, Phantom's Lighthouse heuristics can warn "could be
    # malicious", which is why turf-monster flipped its entries on 2026-06-05.
    #
    # `presign: true` signs the fee payer's slot at build time instead. It exists
    # for flows that still sign server-first (several N-signer operator flows do)
    # so they can adopt this builder before they flip; prefer the default. A
    # presigned wire that a wallet modifies no longer carries a valid fee-payer
    # signature, and Completer refuses it.
    class Builder
      def initialize(client:, fee_payer:)
        @client = client
        @fee_payer = fee_payer
        @fee_payer_bytes = Cosign.key_bytes(fee_payer)
      end

      # instructions: [{ program_id:, accounts: [{ pubkey:, is_signer:, is_writable: }], data: }]
      #   — the hashes Transaction#add_instruction takes (SplToken and
      #   SystemProgram encoders return this shape). Keys may be base58, raw
      #   bytes, or a Keypair.
      # cosigners: public keys whose slots stay empty for the wallet(s).
      # compute_unit_price: micro-lamports per CU (a priority fee). A fee-less
      #   transaction lands on an idle devnet and is dropped by a loaded mainnet.
      # compute_unit_limit: CU cap; the fee is price x limit.
      # commitment: the blockhash is fetched at this commitment and the expectation
      #   carries it, so Completer preflights at the same one.
      def build(instructions:, cosigners:, compute_unit_price: nil, compute_unit_limit: nil,
                commitment: DEFAULT_COMMITMENT, presign: false, fee_margin: DEFAULT_FEE_MARGIN,
                extra_programs: DEFAULT_EXTRA_PROGRAMS)
        if presign && !(@fee_payer.respond_to?(:sign) && @fee_payer.respond_to?(:public_key_bytes))
          raise ArgumentError, "presign: true needs the fee payer as a Solana::Keypair, not a bare public key"
        end

        cosigner_bytes = Array(cosigners).map { |k| Cosign.key_bytes(k) }
        raise ArgumentError, "cosigners must be distinct" unless cosigner_bytes.uniq.size == cosigner_bytes.size
        raise ArgumentError, "the fee payer cannot also be a cosigner" if cosigner_bytes.include?(@fee_payer_bytes)

        built = Array(instructions).map { |ix| normalize_instruction(ix) }
        raise ArgumentError, "at least one instruction is required" if built.empty?

        assert_signers_named!(built, cosigner_bytes)

        latest = @client.latest_blockhash(commitment: commitment)

        tx = Transaction.new
        tx.set_recent_blockhash(latest.blockhash)
        tx.add_signer(@fee_payer) if presign
        tx.add_instruction(**ComputeBudget.set_compute_unit_price(compute_unit_price)) unless compute_unit_price.nil?
        tx.add_instruction(**ComputeBudget.set_compute_unit_limit(compute_unit_limit)) unless compute_unit_limit.nil?
        built.each { |ix| tx.add_instruction(**ix) }

        # Keyless build: Transaction#serialize_partial takes the FIRST additional
        # signer as the fee payer when it holds no local signer.
        additional = presign ? cosigner_bytes : [@fee_payer_bytes, *cosigner_bytes]
        wire = tx.serialize_partial(additional_signers: additional)

        message = WireMessage.parse(wire)
        unless message.fee_payer == @fee_payer_bytes
          raise "Cosign::Builder invariant: account 0 is #{Cosign.base58(message.fee_payer)}, not the fee payer"
        end

        max_price, max_fee = Cosign.fee_caps(compute_unit_price: compute_unit_price,
                                             compute_unit_limit: compute_unit_limit, margin: fee_margin)
        expectation = Expectation.new(
          fee_payer: @fee_payer_bytes,
          cosigners: cosigner_bytes,
          instructions: built,
          last_valid_block_height: latest.last_valid_block_height,
          commitment: commitment,
          max_compute_unit_price: max_price,
          max_priority_fee_micro_lamports: max_fee,
          extra_programs: extra_programs
        )

        Prepared.new(
          wire_base64: message.to_base64,
          blockhash: latest.blockhash,
          last_valid_block_height: latest.last_valid_block_height,
          commitment: commitment,
          fee_payer: Cosign.base58(@fee_payer_bytes),
          signers: message.signer_keys.map { |k| Cosign.base58(k) },
          expectation: expectation
        )
      end

      private

      # Every key normalized to raw bytes BEFORE it reaches Transaction, whose
      # own normalizer reads any 32-byte string as raw — a 32-character base58
      # address included.
      def normalize_instruction(ix)
        raise ArgumentError, "instruction must be a Hash with program_id:, accounts:, data:" unless ix.is_a?(Hash)

        program_id = Cosign.key_bytes(ix.fetch(:program_id))
        if program_id == ComputeBudget::PROGRAM_ID.b
          raise ArgumentError, "pass compute_unit_price:/compute_unit_limit: instead of a ComputeBudget instruction"
        end

        data = ix.fetch(:data)
        {
          program_id: program_id,
          accounts: Array(ix.fetch(:accounts)).map do |meta|
            raise ArgumentError, "account metas must be Hashes with pubkey:" unless meta.is_a?(Hash)

            { pubkey: Cosign.key_bytes(meta.fetch(:pubkey)),
              is_signer: meta[:is_signer] ? true : false,
              is_writable: meta[:is_writable] ? true : false }
          end,
          data: data.is_a?(Array) ? data.pack("C*") : data.to_s.b
        }
      end

      # A signer no one will sign for makes a transaction that can never land;
      # say which key, here, instead of a signer-count mismatch at serialize.
      def assert_signers_named!(built, cosigner_bytes)
        named = [@fee_payer_bytes, *cosigner_bytes]
        built.each_with_index do |ix, n|
          ix[:accounts].each do |meta|
            next unless meta[:is_signer]
            next if named.include?(meta[:pubkey])

            raise ArgumentError, "instruction #{n} requires a signature from #{Cosign.base58(meta[:pubkey])}, " \
                                 "which is neither the fee payer nor a named cosigner"
          end
        end
      end
    end
  end
end
