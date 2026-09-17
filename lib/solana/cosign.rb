module Solana
  # Solana::Cosign — gasless, cosigned transactions, for any app.
  #
  # THE PATTERN. A user's wallet signs in the browser; the SERVER pays the fee.
  # The server builds a transaction with its fee payer in account 0 and an empty
  # signature slot for every named cosigner, hands the wire to the wallet, takes
  # the signed wire back, proves it is still the transaction it built, fills its
  # own slot, simulates, broadcasts and confirms. Users never hold SOL.
  #
  #   builder   = Solana::Cosign::Builder.new(client: client, fee_payer: house_keypair)
  #   prepared  = builder.build(instructions: [ix], cosigners: [user_address],
  #                             compute_unit_price: 50_000, compute_unit_limit: 200_000)
  #   # store prepared.wire_base64 + prepared.last_valid_block_height server-side,
  #   # send prepared.wire_base64 to the wallet, receive signed_wire_base64 back
  #   completer = Solana::Cosign::Completer.new(client: client, fee_payer: house_keypair)
  #   result    = completer.complete(signed_wire_base64, expectation: prepared.expectation,
  #                                  before_send: ->(sig) { record.update!(signature: sig) })
  #
  # WHAT IS DELIBERATELY NOT HERE. No key storage (the caller passes the fee
  # payer keypair in), no environment variables, no program of anyone's, and no
  # durable nonce: a nonce transaction is only recognised when
  # advanceNonceAccount is instruction 0, and Phantom inserts Lighthouse
  # instructions ahead of it, so a nonce cannot anchor a wallet-signed
  # transaction (turf-monster mainnet incident, 2026-06-11).
  #
  # THE ERROR HIERARCHY IS THE SAFETY SEAM. What a caller may do after a failure
  # depends on one question it cannot answer afterwards — did the bytes leave?
  #
  #   Cosign::Error
  #     WireRejected        the wire is not what was built; nothing was sent
  #     PreflightRejected   provably never sent: rebuild freely
  #       BlockhashExpired  block height is already past last_valid_block_height
  #       SimulationFailed  the program refused it (#err, #logs)
  #     BroadcastFailed     MAY be on chain: reconcile #signature before rebuilding
  #       BroadcastExpired  the node or the chain says the blockhash is dead
  #     TransactionFailed   landed on chain and failed (#err); the fee was paid
  #
  # A caller that rewinds a claim on anything under BroadcastFailed can re-send a
  # transaction that already landed. `rescue Solana::Cosign::PreflightRejected`
  # is the only rescue that licenses a silent rebuild.
  module Cosign
    DEFAULT_COMMITMENT = "confirmed"

    # The wallet may raise the priority fee on its own under load, so the cosign
    # CAPS rather than refuses: at most this many times the builder's own price,
    # and this many times the builder's whole priority fee. A builder price of 0
    # makes both caps 0, so no wallet-added fee is ever paid for.
    DEFAULT_FEE_MARGIN = 10

    # Lighthouse, Phantom's transaction-protection program. On mainnet Phantom
    # may insert Lighthouse assertion instructions into a transaction it signs.
    # They are post-state assertions: they can make a transaction fail, never
    # move funds or grant authority, so admitting them keeps the fee payer safe.
    # Without this every protected Phantom signature is refused (turf-monster,
    # 2026-06-11).
    LIGHTHOUSE_PROGRAM_ID = Keypair.decode_base58("L2TExMFKdjpN9kozasaurPirfHy9P8sbXoAN1qA3S95").freeze

    DEFAULT_EXTRA_PROGRAMS = [LIGHTHOUSE_PROGRAM_ID].freeze

    BASE58_PUBKEY = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/

    class Error < StandardError
      # The transaction's first signature (base58), when one exists. Present on
      # every error raised after the fee payer's slot is filled, so a caller can
      # log it, and — for BroadcastFailed — look it up on chain.
      attr_reader :signature

      def initialize(message = nil, signature: nil)
        @signature = signature
        super(message)
      end
    end

    # The returned wire is not the transaction the server built, or cannot be
    # completed. Raised before the fee payer signs; nothing is returned or sent.
    # #reason is a short stable code; the message carries detail for SERVER LOGS
    # ONLY — never echo it to a client, it tells an attacker which check tripped.
    class WireRejected < Error
      attr_reader :reason

      def initialize(reason, detail = nil)
        @reason = reason.to_s
        super(detail ? "#{@reason}: #{detail}" : @reason)
      end
    end

    # Signed in memory, provably never sent.
    class PreflightRejected < Error; end

    class BlockhashExpired < PreflightRejected
      attr_reader :block_height, :last_valid_block_height

      def initialize(message = nil, signature: nil, block_height: nil, last_valid_block_height: nil)
        @block_height = block_height
        @last_valid_block_height = last_valid_block_height
        super(message, signature: signature)
      end
    end

    class SimulationFailed < PreflightRejected
      attr_reader :err, :logs

      def initialize(message = nil, signature: nil, err: nil, logs: [])
        @err = err
        @logs = Array(logs)
        super(message, signature: signature)
      end
    end

    # Everything from the send onward. Solana::Client#call retries a read
    # timeout or a reset connection by re-posting the same wire, and hands back
    # only the last answer, so no exception from a send proves the transaction
    # was not forwarded. Reconcile #signature against the chain before rebuilding.
    class BroadcastFailed < Error; end

    class BroadcastExpired < BroadcastFailed; end

    class TransactionFailed < Error
      attr_reader :err

      def initialize(message = nil, signature: nil, err: nil)
        @err = err
        super(message, signature: signature)
      end
    end

    module_function

    # Normalize a public key to its 32 raw bytes. Accepts a Solana::Keypair, a
    # base58 address, or 32 raw bytes. A BINARY string of 32 bytes is always raw;
    # a string that reads as base58 is decoded. (That order matters: a 32-byte
    # raw key can happen to be 32 base58-legal characters.)
    def key_bytes(value)
      return value.public_key_bytes.b if value.respond_to?(:public_key_bytes)
      raise ArgumentError, "public key required, got #{value.inspect}" unless value.is_a?(String) && !value.empty?
      return value.b if value.encoding == Encoding::BINARY && value.bytesize == 32

      if value.match?(BASE58_PUBKEY)
        # Keypair.decode_base58 answers 33 bytes for the all-'1' address (the
        # System Program id), so that one is spelled out.
        return ("\x00" * 32).b if value == "1" * 32

        decoded = Keypair.decode_base58(value)
        return decoded.b if decoded.bytesize == 32
      end
      return value.b if value.bytesize == 32

      raise ArgumentError, "not a 32-byte public key: #{value.inspect}"
    end

    def base58(bytes)
      Keypair.encode_base58(bytes)
    end

    # [max_compute_unit_price, max_priority_fee_micro_lamports] for a builder
    # that set this price and limit. See DEFAULT_FEE_MARGIN.
    def fee_caps(compute_unit_price:, compute_unit_limit:, margin: DEFAULT_FEE_MARGIN)
      price = Integer(compute_unit_price || 0)
      limit = Integer(compute_unit_limit || ComputeBudget::MAX_COMPUTE_UNIT_LIMIT)
      margin = Integer(margin)
      raise ArgumentError, "fee margin must be >= 1, got #{margin}" if margin < 1

      [price * margin, price * limit * margin]
    end
  end
end

require_relative "cosign/expectation"
require_relative "cosign/builder"
require_relative "cosign/completer"
