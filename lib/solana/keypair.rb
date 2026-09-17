require "ed25519"
require "securerandom"
require "json"

module Solana
  class Keypair
    BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

    attr_reader :signing_key, :verify_key

    def initialize(signing_key)
      @signing_key = signing_key
      @verify_key = signing_key.verify_key
    end

    # Generate a new random keypair
    def self.generate
      new(Ed25519::SigningKey.generate)
    end

    # Load from raw 64-byte secret key (Solana format: 32-byte private + 32-byte public)
    def self.from_bytes(bytes)
      bytes = bytes.pack("C*") if bytes.is_a?(Array)
      private_key = bytes[0, 32]
      new(Ed25519::SigningKey.new(private_key))
    end

    # Load from Solana CLI keypair JSON file (array of 64 bytes)
    def self.from_json_file(path)
      bytes = JSON.parse(File.read(path))
      from_bytes(bytes)
    end

    # Load from base58-encoded secret key (e.g. from env var)
    def self.from_base58(secret_key_base58)
      bytes = decode_base58(secret_key_base58)
      from_bytes(bytes)
    end

    # Public key as 32 bytes
    def public_key_bytes
      @verify_key.to_bytes
    end

    # Public key as base58 string (Solana address)
    def to_base58
      self.class.encode_base58(public_key_bytes)
    end
    alias_method :address, :to_base58

    # Sign a message
    def sign(message)
      message = message.pack("C*") if message.is_a?(Array)
      @signing_key.sign(message)
    end

    # Full 64-byte secret key (Solana format)
    def to_bytes
      @signing_key.to_bytes + public_key_bytes
    end

    # --- Base58 utilities ---

    def self.encode_base58(bytes)
      bytes = bytes.b if bytes.is_a?(String)
      num = bytes.unpack1("H*").to_i(16)

      result = ""
      while num > 0
        num, remainder = num.divmod(58)
        result = BASE58_ALPHABET[remainder] + result
      end

      # Preserve leading zero bytes
      bytes.each_byte do |byte|
        break unless byte == 0
        result = "1" + result
      end

      result
    end

    def self.decode_base58(string)
      raise ArgumentError, "decode_base58 requires a non-empty String, got #{string.inspect}" if string.nil? || string.empty?

      num = 0
      string.each_char do |c|
        idx = BASE58_ALPHABET.index(c)
        raise ArgumentError, "Invalid base58 character #{c.inspect} (not in alphabet: 0OIl excluded)" unless idx
        num = num * 58 + idx
      end

      # A value of zero has NO body: every byte of it is a leading '1', counted
      # below. `0.to_s(16)` is "0", which padded to "00" used to add a 33rd byte
      # to the all-'1' System Program id.
      hex = num.zero? ? "" : num.to_s(16)
      hex = "0" + hex if hex.length.odd?

      # Count leading '1's (zero bytes)
      leading_zeros = string.chars.take_while { |c| c == "1" }.length
      bytes = [("00" * leading_zeros) + hex].pack("H*")
      bytes
    end

    def self.pubkey_from_base58(address)
      decode_base58(address)
    end
  end
end
