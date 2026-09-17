require "base64"
require_relative "test_helper"

# Shared fixtures for the Solana::Cosign suites. Every key here is a throwaway
# generated in-process; nothing touches a network.
module CosignSupport
  # A stand-in for Solana::Client that answers from canned values and records
  # every call in order, so a test can assert both WHAT was asked and WHEN
  # (nothing may be sent before a refusal, the signature must be recorded before
  # the send).
  class FakeRpcClient
    attr_reader :calls
    attr_accessor :blockhash, :last_valid_block_height, :block_heights, :simulation,
                  :send_result, :statuses

    def initialize(blockhash:, last_valid_block_height: 1_000)
      @blockhash = blockhash
      @last_valid_block_height = last_valid_block_height
      @block_heights = [900]
      @simulation = { "err" => nil, "logs" => ["Program log: ok"] }
      @send_result = :echo_signature
      @statuses = [{ "err" => nil, "confirmationStatus" => "confirmed" }]
      @calls = []
    end

    def latest_blockhash(commitment:)
      @calls << [:latest_blockhash, { commitment: commitment }]
      Solana::Client::LatestBlockhash.new(blockhash: @blockhash, last_valid_block_height: @last_valid_block_height,
                                          slot: 42, commitment: commitment)
    end

    def get_block_height(commitment:)
      @calls << [:get_block_height, { commitment: commitment }]
      value = @block_heights.size > 1 ? @block_heights.shift : @block_heights.first
      raise value if value.is_a?(Exception)

      value
    end

    def simulate_transaction(wire_base64, sig_verify:, replace_recent_blockhash:, commitment:)
      @calls << [:simulate_transaction, { wire: wire_base64, sig_verify: sig_verify,
                                          replace_recent_blockhash: replace_recent_blockhash, commitment: commitment }]
      raise @simulation if @simulation.is_a?(Exception)

      @simulation
    end

    def send_transaction(wire_base64, preflight_commitment: nil)
      @calls << [:send_transaction, { wire: wire_base64, preflight_commitment: preflight_commitment }]
      raise @send_result if @send_result.is_a?(Exception)
      return Solana::WireMessage.parse_base64(wire_base64).signature if @send_result == :echo_signature

      @send_result
    end

    def confirm_transaction(signature)
      @calls << [:confirm_transaction, { signature: signature }]
      value = @statuses.size > 1 ? @statuses.shift : @statuses.first
      raise value if value.is_a?(Exception)

      { "context" => { "slot" => 50 }, "value" => [value] }
    end

    def called?(name)
      @calls.any? { |call, _| call == name }
    end

    def call_names
      @calls.map(&:first)
    end
  end

  BLOCKHASH = Solana::Keypair.encode_base58(("\x07" * 32).b)
  OTHER_BLOCKHASH = Solana::Keypair.encode_base58(("\x09" * 32).b)
  LIGHTHOUSE = Solana::Cosign::LIGHTHOUSE_PROGRAM_ID
  SYSTEM = Solana::Transaction::SYSTEM_PROGRAM_ID.b
  PRICE = 50_000
  LIMIT = 200_000

  def house
    @house ||= Solana::Keypair.generate
  end

  def user
    @user ||= Solana::Keypair.generate
  end

  def app_program
    @app_program ||= Solana::Keypair.generate.public_key_bytes
  end

  def app_state
    @app_state ||= Solana::Keypair.generate.public_key_bytes
  end

  def rpc
    @rpc ||= FakeRpcClient.new(blockhash: BLOCKHASH)
  end

  # An app instruction the USER must authorise: the kind of thing a game entry,
  # a purchase or a vote is. `amount` is in the data so a test can alter it.
  def app_instruction(amount: 1_000_000, state: app_state, signer: user.public_key_bytes)
    {
      program_id: app_program,
      accounts: [
        { pubkey: signer, is_signer: true, is_writable: true },
        { pubkey: state, is_signer: false, is_writable: true },
        { pubkey: SYSTEM, is_signer: false, is_writable: false }
      ],
      data: Solana::Transaction.anchor_discriminator("do_thing") + [amount].pack("Q<")
    }
  end

  # A Lighthouse ASSERTION, the only kind of Lighthouse instruction the guard
  # admits. The data is a real AssertAccountInfoMulti (variant 6) Phantom put
  # into a cosigned mainnet transaction; test/cosign_lighthouse_test.rb carries
  # every other one, and the variants the guard refuses.
  def lighthouse_instruction(data: ["06040203000001000000000000000000"].pack("H*"), accounts: nil)
    {
      program_id: LIGHTHOUSE,
      accounts: accounts || [{ pubkey: app_state, is_signer: false, is_writable: false }],
      data: data.b
    }
  end

  def system_transfer_from(from, to, lamports)
    {
      program_id: SYSTEM,
      accounts: [
        { pubkey: from, is_signer: true, is_writable: true },
        { pubkey: to, is_signer: false, is_writable: true }
      ],
      data: [2].pack("V") + [lamports].pack("Q<")
    }
  end

  def builder
    Solana::Cosign::Builder.new(client: rpc, fee_payer: house)
  end

  def completer(**opts)
    Solana::Cosign::Completer.new(client: rpc, fee_payer: house, sleeper: ->(_) {}, **opts)
  end

  def prepare(**opts)
    builder.build(instructions: [app_instruction], cosigners: [user.public_key_bytes],
                  compute_unit_price: PRICE, compute_unit_limit: LIMIT, **opts)
  end

  # What a WALLET hands back, assembled independently of Cosign::Builder so the
  # completer is judged against bytes it did not produce. `before` / `after` are
  # instructions the wallet inserts; `compute` is the ComputeBudget it ends up with.
  def wallet_wire(instructions: [app_instruction], before: [], after: [], price: PRICE, limit: LIMIT,
                  fee_payer: house.public_key_bytes, cosigners: [user.public_key_bytes], blockhash: BLOCKHASH,
                  extra_compute: [])
    tx = Solana::Transaction.new
    tx.set_recent_blockhash(blockhash)
    before.each { |ix| tx.add_instruction(**ix) }
    tx.add_instruction(**Solana::ComputeBudget.set_compute_unit_price(price)) unless price.nil?
    tx.add_instruction(**Solana::ComputeBudget.set_compute_unit_limit(limit)) unless limit.nil?
    extra_compute.each { |ix| tx.add_instruction(**ix) }
    instructions.each { |ix| tx.add_instruction(**ix) }
    after.each { |ix| tx.add_instruction(**ix) }
    tx.serialize_partial(additional_signers: [fee_payer, *cosigners])
  end

  # Fill the given keypairs' slots, as each wallet would, leaving the rest empty.
  def signed_by(wire, *keypairs)
    keypairs.reduce(wire.b) { |w, kp| Solana::Transaction.cosign_wire(w, signer: kp, require_complete: false) }
  end

  def b64(bytes)
    Base64.strict_encode64(bytes)
  end

  def user_signed(prepared)
    b64(signed_by(Base64.strict_decode64(prepared.wire_base64), user))
  end

  # ---- raw message assembly, for shapes Solana::Transaction will not emit ----

  def compact_u16(value)
    bytes = []
    loop do
      byte = value & 0x7F
      value >>= 7
      byte |= 0x80 if value.positive?
      bytes << byte
      break if value.zero?
    end
    bytes.pack("C*")
  end

  # instructions: [[program_index, [account_indices], data]]
  def raw_message(header:, keys:, blockhash:, instructions:)
    msg = header.pack("CCC").b
    msg << compact_u16(keys.size)
    keys.each { |k| msg << k.b }
    msg << Solana::Keypair.decode_base58(blockhash).b
    msg << compact_u16(instructions.size)
    instructions.each do |program_index, indices, data|
      msg << [program_index].pack("C") << compact_u16(indices.size) << indices.pack("C*")
      msg << compact_u16(data.bytesize) << data.b
    end
    msg
  end

  def raw_wire(message, signature_count)
    (compact_u16(signature_count) + ("\x00" * 64 * signature_count) + message).b
  end
end
