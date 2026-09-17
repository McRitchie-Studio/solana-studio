require "base64"
require "ed25519"
require_relative "ed25519_strict"

module Solana
  # A decoded LEGACY wire transaction: the signature array plus the message it
  # signs. Pure — no RPC, no keys.
  #
  # WHY A SERVER NEEDS TO READ ITS OWN WIRE BACK. A wallet does not return the
  # bytes it was given. It re-serializes them, and on mainnet Phantom may insert
  # Lighthouse assertion instructions (and their accounts) before signing, so a
  # byte comparison against the prepared wire refuses legitimate signatures. A
  # cosigning server has to decode what came back and judge it by meaning. This
  # is the decoder turf-monster kept privately in Vault#parse_wire_message, and
  # the walk Transaction.cosign_wire does inline.
  #
  # FAILS CLOSED. Truncation, trailing bytes, an out-of-range index and a
  # versioned (v0+) message all raise MalformedError. Versioned messages are
  # refused rather than half-read: this decoder cannot walk address-table
  # lookups, and Solana::Transaction only ever builds legacy messages.
  class WireMessage
    class MalformedError < ArgumentError; end

    EMPTY_SIGNATURE = ("\x00" * 64).b.freeze

    attr_reader :signatures, :message_bytes, :num_required_signatures,
                :num_readonly_signed, :num_readonly_unsigned,
                :account_keys, :recent_blockhash, :instructions

    def self.parse_base64(wire_base64)
      raise MalformedError, "wire is empty" if wire_base64.nil? || wire_base64.to_s.empty?

      parse(Base64.strict_decode64(wire_base64.to_s))
    rescue ArgumentError => e
      raise e if e.is_a?(MalformedError)

      raise MalformedError, "wire is not strict base64: #{e.message}"
    end

    # Base58 is the wire format of the gem's own browser seam (walletOps hands
    # `prepare` and `complete` base58), so a host can pass it straight through.
    def self.parse_base58(wire_base58)
      raise MalformedError, "wire is empty" if wire_base58.nil? || wire_base58.to_s.empty?

      parse(Keypair.decode_base58(wire_base58.to_s))
    rescue ArgumentError => e
      raise e if e.is_a?(MalformedError)

      raise MalformedError, "wire is not base58: #{e.message}"
    end

    # encoding: :base64 or :base58. Explicit, never sniffed: every base58
    # string is also made of base64 characters, so guessing can misread one.
    def self.parse_encoded(wire, encoding)
      case encoding
      when :base64 then parse_base64(wire)
      when :base58 then parse_base58(wire)
      else raise ArgumentError, "encoding must be :base64 or :base58, got #{encoding.inspect}"
      end
    end

    # `wire` is the binary wire transaction: compact-u16 signature count, the
    # 64-byte signatures, then the message.
    def self.parse(wire)
      new(wire.to_s.b)
    end

    def initialize(wire)
      @wire = wire
      cursor = 0

      sig_count, cursor = read_compact_u16(cursor)
      malformed!("zero signature slots") if sig_count.zero?
      need!(cursor + (sig_count * 64), "signature array")
      @signatures = Array.new(sig_count) { |i| @wire.byteslice(cursor + (i * 64), 64) }
      message_start = cursor + (sig_count * 64)
      @message_bytes = @wire.byteslice(message_start, @wire.bytesize - message_start)

      need!(message_start + 3, "message header")
      first = @wire.getbyte(message_start)
      malformed!("versioned (v0+) message is not supported") if (first & 0x80) != 0
      @num_required_signatures = first
      @num_readonly_signed = @wire.getbyte(message_start + 1)
      @num_readonly_unsigned = @wire.getbyte(message_start + 2)

      unless @num_required_signatures == sig_count
        malformed!("header requires #{@num_required_signatures} signature(s) but the wire carries #{sig_count} slot(s)")
      end

      cursor = message_start + 3
      account_count, cursor = read_compact_u16(cursor)
      need!(cursor + (account_count * 32), "account keys")
      @account_keys = Array.new(account_count) { |i| @wire.byteslice(cursor + (i * 32), 32) }
      cursor += account_count * 32
      malformed!("#{account_count} account key(s) cannot cover #{@num_required_signatures} signer(s)") if account_count < @num_required_signatures
      # The runtime refuses a key loaded twice. Refusing it here too means a
      # signer check and an instruction check can never read two different
      # entries for the same key.
      malformed!("duplicate account key in the account list") unless @account_keys.uniq.size == account_count
      if @num_readonly_signed > @num_required_signatures || @num_readonly_unsigned > (account_count - @num_required_signatures)
        malformed!("readonly counts exceed the account list")
      end

      need!(cursor + 32, "recent blockhash")
      @recent_blockhash = @wire.byteslice(cursor, 32)
      cursor += 32

      ix_count, cursor = read_compact_u16(cursor)
      @instructions = Array.new(ix_count) do |n|
        need!(cursor + 1, "instruction #{n} program index")
        program_id_index = @wire.getbyte(cursor)
        cursor += 1
        malformed!("instruction #{n} program index #{program_id_index} is out of range") if program_id_index >= account_count

        accounts_len, cursor = read_compact_u16(cursor)
        need!(cursor + accounts_len, "instruction #{n} account indices")
        account_indices = @wire.byteslice(cursor, accounts_len).bytes
        cursor += accounts_len
        bad = account_indices.find { |idx| idx >= account_count }
        malformed!("instruction #{n} account index #{bad} is out of range") if bad

        data_len, cursor = read_compact_u16(cursor)
        need!(cursor + data_len, "instruction #{n} data")
        data = @wire.byteslice(cursor, data_len)
        cursor += data_len

        {
          program_id_index: program_id_index,
          program_id: @account_keys[program_id_index],
          account_indices: account_indices,
          accounts: account_indices.map { |idx| @account_keys[idx] },
          data: data
        }
      end

      malformed!("#{@wire.bytesize - cursor} trailing byte(s) after the last instruction") unless cursor == @wire.bytesize
    end

    def to_bytes
      @wire.dup
    end

    def to_base64
      Base64.strict_encode64(@wire)
    end

    def to_base58
      Keypair.encode_base58(@wire)
    end

    # The fee payer: account 0, always the first signer.
    def fee_payer
      @account_keys[0]
    end

    def signer_keys
      @account_keys.first(@num_required_signatures)
    end

    def signer?(key_or_index)
      index = key_or_index.is_a?(Integer) ? key_or_index : @account_keys.index(key_or_index.to_s.b)
      !index.nil? && index < @num_required_signatures
    end

    # Standard legacy layout: writable signers, readonly signers, writable
    # non-signers, readonly non-signers.
    def writable?(key_or_index)
      index = key_or_index.is_a?(Integer) ? key_or_index : @account_keys.index(key_or_index.to_s.b)
      return false if index.nil? || index >= @account_keys.length

      if index < @num_required_signatures
        index < (@num_required_signatures - @num_readonly_signed)
      else
        (index - @num_required_signatures) < (@account_keys.length - @num_required_signatures - @num_readonly_unsigned)
      end
    end

    def signature_slot_empty?(index)
      @signatures.fetch(index) == EMPTY_SIGNATURE
    end

    # True when slot `index` holds a valid ed25519 signature, by the key in that
    # signer slot, over these exact message bytes. An empty slot is not valid.
    # Strict (Solana::Ed25519Strict): a slot the cluster's own signature check
    # would refuse — a small-order key or R, an unreduced S — is not valid here
    # either, so a completer refuses it before the fee payer signs.
    def signature_valid?(index)
      return false if index >= @num_required_signatures || signature_slot_empty?(index)

      Ed25519Strict.verify(@account_keys[index], @signatures[index], @message_bytes)
    end

    # The transaction's identity on chain: its FIRST signature (the fee payer's),
    # base58. Knowable before any broadcast, which is what lets a caller record
    # it before the bytes leave. Raises when that slot is still empty, because an
    # all-zero "signature" names nothing.
    def signature
      raise MalformedError, "the fee-payer slot is empty, so this wire has no signature yet" if signature_slot_empty?(0)

      Keypair.encode_base58(@signatures[0])
    end

    def recent_blockhash_base58
      Keypair.encode_base58(@recent_blockhash)
    end

    private

    def read_compact_u16(offset)
      Transaction.read_compact_u16(@wire, offset)
    rescue RuntimeError => e
      malformed!(e.message)
    end

    def need!(end_offset, what)
      malformed!("truncated #{what}") if @wire.bytesize < end_offset
    end

    def malformed!(reason)
      raise MalformedError, "malformed wire: #{reason}"
    end
  end
end
