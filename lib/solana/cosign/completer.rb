module Solana
  module Cosign
    # Takes a wallet-signed wire back, and finishes it — or refuses it.
    #
    # Three levels, so a flow can stop where its broadcast lives:
    #
    #   #verify!   judge the wire against the Expectation. No key, no RPC.
    #   #cosign    verify, check every cosigner signature, fill the fee payer's
    #              slot (Transaction.cosign_wire). No RPC. For a flow whose
    #              browser broadcasts.
    #   #complete  cosign, check the deadline, simulate, record, send, confirm.
    #
    # THE FEE PAYER SIGNS LAST, AND ONLY WHAT PASSED. Every check that can refuse
    # the wire runs before the fee payer's key is used, so a refused wire leaves
    # nothing behind that could be broadcast.
    class Completer
      Cosigned = Struct.new(:wire_base64, :signature, :message, keyword_init: true) do
        def wire_base58
          message.to_base58
        end
      end
      Completed = Struct.new(:signature, :wire_base64, :confirmation_status, keyword_init: true)

      COMMITMENT_RANK = { "processed" => 0, "confirmed" => 1, "finalized" => 2 }.freeze

      # fee_payer: the Solana::Keypair whose slot this server fills. Passed in;
      # this class never loads, stores or derives a key.
      # sleeper / clock / poll_interval: injectable so the confirmation loop can be
      # tested without waiting on a real clock.
      def initialize(client:, fee_payer:, poll_interval: 1,
                     sleeper: ->(seconds) { sleep(seconds) },
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        unless fee_payer.respond_to?(:sign) && fee_payer.respond_to?(:public_key_bytes)
          raise ArgumentError, "fee_payer must be a Solana::Keypair — the completer signs with it"
        end

        @client = client
        @fee_payer = fee_payer
        @fee_payer_bytes = fee_payer.public_key_bytes.b
        @poll_interval = poll_interval
        @sleeper = sleeper
        @clock = clock
      end

      # signed_wire: the wallet-returned wire, base64 by default; pass
      # `encoding: :base58` for what SolanaStudio.walletOps hands `complete`.
      # Returns the decoded WireMessage, or raises WireRejected.
      def verify!(signed_wire, expectation:, encoding: :base64)
        unless expectation.fee_payer == @fee_payer_bytes
          # A wiring mistake in the caller, not something the wire did.
          raise ArgumentError, "the expectation's fee payer #{Cosign.base58(expectation.fee_payer)} " \
                               "is not this completer's key #{Cosign.base58(@fee_payer_bytes)}"
        end

        message =
          begin
            WireMessage.parse_encoded(signed_wire, encoding)
          rescue WireMessage::MalformedError => e
            raise WireRejected.new(:unparseable_wire, e.message)
          end
        expectation.verify!(message)
        message
      end

      # Returns Cosigned(wire_base64, signature, message). The signature is the
      # transaction's id, known BEFORE anything is sent: record it first.
      def cosign(signed_wire, expectation:, encoding: :base64)
        message = verify!(signed_wire, expectation: expectation, encoding: encoding)

        # Every cosigner slot must already hold a valid signature over THESE
        # bytes. An empty or forged slot is refused here, before the fee payer
        # signs — rather than by the node, after the fee payer has.
        (1...message.num_required_signatures).each do |slot|
          signer = Cosign.base58(message.account_keys[slot])
          raise WireRejected.new(:signature_missing, "slot #{slot} (#{signer}) is unsigned") if message.signature_slot_empty?(slot)
          raise WireRejected.new(:signature_invalid, "slot #{slot} (#{signer}) does not verify") unless message.signature_valid?(slot)
        end

        wire =
          if message.signature_slot_empty?(0)
            Transaction.cosign_wire(message.to_bytes, signer: @fee_payer, require_complete: true)
          elsif message.signature_valid?(0)
            message.to_bytes # presigned at build, and the message is unchanged since
          else
            raise WireRejected.new(:fee_payer_signature_invalid,
                                   "slot 0 holds a signature that does not verify over this message — " \
                                   "the transaction changed after the fee payer signed it")
          end

        signed = WireMessage.parse(wire)
        Cosigned.new(wire_base64: signed.to_base64, signature: signed.signature, message: signed)
      end

      # Cosign, then put it on chain.
      #
      # before_send: called with the signature after every provable check and
      #   before the send. Persist it there. If it raises, nothing is sent and the
      #   exception propagates unchanged.
      # simulate: run simulateTransaction first (sigVerify false — the signatures
      #   were verified locally; replaceRecentBlockhash true — the deadline check
      #   judges the blockhash, the simulation judges the program).
      # confirm_timeout: seconds to wait for the expectation's commitment; nil
      #   returns right after the send with confirmation_status nil.
      def complete(signed_wire, expectation:, encoding: :base64, simulate: true, before_send: nil, confirm_timeout: 30)
        cosigned = cosign(signed_wire, expectation: expectation, encoding: encoding)
        signature = cosigned.signature
        wire_base64 = cosigned.wire_base64
        commitment = expectation.commitment

        assert_not_expired!(expectation, signature)
        run_simulation!(wire_base64, commitment, signature) if simulate

        before_send&.call(signature)

        returned =
          begin
            @client.send_transaction(wire_base64, preflight_commitment: commitment)
          rescue StandardError => e
            if blockhash_not_found?(e)
              raise BroadcastExpired.new("the node no longer knows this blockhash: #{e.message}", signature: signature)
            end

            raise BroadcastFailed.new("send failed — reconcile #{signature} before rebuilding: #{e.message}", signature: signature)
          end

        if returned && returned != signature
          raise BroadcastFailed.new("the node returned #{returned} for a wire whose own first signature is #{signature} — " \
                                    "reconcile both on chain before acting", signature: signature)
        end

        return Completed.new(signature: signature, wire_base64: wire_base64, confirmation_status: nil) if confirm_timeout.nil?

        status = await_confirmation!(signature, expectation, confirm_timeout)
        Completed.new(signature: signature, wire_base64: wire_base64, confirmation_status: status)
      end

      private

      def assert_not_expired!(expectation, signature)
        limit = expectation.last_valid_block_height
        return if limit.nil?

        height =
          begin
            @client.get_block_height(commitment: expectation.commitment)
          rescue StandardError => e
            raise PreflightRejected.new("could not read the block height to check the deadline: #{e.message}", signature: signature)
          end
        return if height <= limit

        raise BlockhashExpired.new("blockhash expired: block height #{height} is past last valid height #{limit}",
                                   signature: signature, block_height: height, last_valid_block_height: limit)
      end

      def run_simulation!(wire_base64, commitment, signature)
        result =
          begin
            @client.simulate_transaction(wire_base64, sig_verify: false, replace_recent_blockhash: true, commitment: commitment)
          rescue StandardError => e
            raise PreflightRejected.new("simulation could not be run: #{e.message}", signature: signature)
          end
        return unless result && result["err"]

        logs = Array(result["logs"])
        raise SimulationFailed.new("simulation failed: #{result['err'].inspect}", signature: signature,
                                   err: result["err"], logs: logs)
      end

      # Polls until the expectation's commitment is reached. A status read that
      # fails is not a verdict; the loop keeps asking until the deadline.
      def await_confirmation!(signature, expectation, timeout)
        wanted = COMMITMENT_RANK.fetch(expectation.commitment, COMMITMENT_RANK["confirmed"])
        deadline = @clock.call + timeout

        loop do
          @sleeper.call(@poll_interval)
          status = read_status(signature)

          if status
            if status["err"]
              raise TransactionFailed.new("landed and failed: #{status['err'].inspect}", signature: signature, err: status["err"])
            end

            reached = COMMITMENT_RANK[status["confirmationStatus"].to_s]
            return status["confirmationStatus"] if reached && reached >= wanted
          elsif chain_says_expired?(expectation)
            raise BroadcastExpired.new("no status for #{signature} and the block height is past its last valid height",
                                       signature: signature)
          end

          if @clock.call > deadline
            raise BroadcastFailed.new("confirmation timed out after #{timeout}s — reconcile #{signature} before rebuilding",
                                      signature: signature)
          end
        end
      end

      def read_status(signature)
        @client.confirm_transaction(signature)&.dig("value", 0)
      rescue StandardError
        nil
      end

      def chain_says_expired?(expectation)
        return false if expectation.last_valid_block_height.nil?

        @client.get_block_height(commitment: expectation.commitment) > expectation.last_valid_block_height
      rescue StandardError
        false
      end

      def blockhash_not_found?(error)
        error.message.to_s.match?(/blockhash not found/i)
      end
    end
  end
end
