require "digest"

# Signatures the `ed25519` gem accepts and Solana::Ed25519Strict must refuse.
#
# Every helper here builds its signature by hand and every test that uses one
# first asserts that the RAW library (Ed25519::VerifyKey) accepts it. That
# control is what makes a refusal mean something: a vector the library already
# rejects would pass these tests with the strict checks deleted.
module Ed25519ForgerySupport
  STRICT = Solana::Ed25519Strict
  L = STRICT::L

  BASE_POINT = STRICT.decode_point(["58#{'66' * 31}"].pack("H*"))

  # Every 32-byte string the library decodes to a small-order point: the eight
  # canonical encodings, then six non-canonical aliases (y >= p, negative zero).
  SMALL_ORDER_CANONICAL = {
    "4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofM"  => "0100000000000000000000000000000000000000000000000000000000000000",
    "Gx9dDNxzpALCowVuZb7pBceBLJugLA8sPa6TJDXrpfeW" => "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "11111111111111111111111111111111"             => "0000000000000000000000000000000000000000000000000000000000000000",
    "11111111111111111111111111111113D"            => "0000000000000000000000000000000000000000000000000000000000000080",
    "3ctC68zTqpRDQShoondiQKDHwZDAUjRyxiPNdg8cD6Pe" => "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
    "3ctC68zTqpRDQShoondiQKDHwZDAUjRyxiPNdg8cD6Rr" => "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
    "EQAqmjhcsBQhpBv5GJkYgEB7emGHZNoo1j1yAjiFLNvD" => "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
    "EQAqmjhcsBQhpBv5GJkYgEB7emGHZNoo1j1yAjiFLNxR" => "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa"
  }.freeze

  SMALL_ORDER_ALIASES = {
    "4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziohZ"  => "0100000000000000000000000000000000000000000000000000000000000080",
    "H5xSWNRAbqKddKjrabehyU8drL3Dk4LgZJiEJc9rGGyC" => "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "H5xSWNRAbqKddKjrabehyU8drL3Dk4LgZJiEJc9rGH1Q" => "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "Gx9dDNxzpALCowVuZb7pBceBLJugLA8sPa6TJDXrpfgi" => "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "H242rsh5hzpvDdct56PG5YPQbKUT37EmySQLoQqrYUJr" => "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "H242rsh5hzpvDdct56PG5YPQbKUT37EmySQLoQqrYUM4" => "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }.freeze

  SMALL_ORDER_KEYS = SMALL_ORDER_CANONICAL.merge(SMALL_ORDER_ALIASES).freeze

  GRIND_LIMIT = 256

  def hex_bytes(hex)
    [hex].pack("H*").b
  end

  def library_accepts?(public_key, signature, message)
    Ed25519::VerifyKey.new(public_key).verify(signature, message)
  rescue Ed25519::VerifyError, ArgumentError
    false
  end

  # R = the identity, S = 0: the keyless signature a small-order key admits.
  def keyless_signature
    STRICT.encode_point(STRICT::IDENTITY) + ("\x00" * 32).b
  end

  # Grinds `message_for.call(i)` until the library accepts `signature_for` over
  # it. Returns [message, signature, i]; flunks if the control never fires.
  def grind(public_key, message_for:, signature_for:)
    GRIND_LIMIT.times do |i|
      message = message_for.call(i)
      signature = signature_for.call(message)
      return [message, signature, i] if library_accepts?(public_key, signature, message)
    end
    flunk "control failed: the library refused all #{GRIND_LIMIT} candidates, so this vector proves nothing"
  end

  def clamped_scalar(seed)
    digest = Digest::SHA512.digest(seed)
    a = STRICT.le_int(digest.byteslice(0, 32))
    a &= ~7
    a &= (1 << 254) - 1
    a | (1 << 254)
  end

  def le_bytes(int, size = 32)
    Array.new(size) { |i| (int >> (8 * i)) & 0xff }.pack("C*").b
  end

  def challenge(r_bytes, public_key, message)
    STRICT.le_int(Digest::SHA512.digest(r_bytes + public_key + message.b)) % L
  end

  # A standard ed25519 signature by `seed`'s scalar, except the challenge hashes
  # `claimed_key` in place of the real public key.
  def sign_as(seed, claimed_key, message)
    a = clamped_scalar(seed)
    r = STRICT.le_int(Digest::SHA512.digest(Digest::SHA512.digest(seed).byteslice(32, 32) + message.b)) % L
    r_bytes = STRICT.encode_point(STRICT.scalar_mult(r, BASE_POINT))
    h = challenge(r_bytes, claimed_key, message)
    r_bytes + le_bytes((r + h * a) % L)
  end

  # The key's own secret, with R = the identity: S = h·a.
  def sign_with_identity_r(seed, message)
    public_key = Solana::Keypair.new(Ed25519::SigningKey.new(seed)).public_key_bytes
    r_bytes = STRICT.encode_point(STRICT::IDENTITY)
    h = challenge(r_bytes, public_key, message)
    r_bytes + le_bytes((h * clamped_scalar(seed)) % L)
  end

  # seed's public key plus an order-8 point: a valid, non-small-order curve
  # point outside the prime-order subgroup.
  def mixed_order_key(seed)
    torsion = STRICT.decode_point(hex_bytes(SMALL_ORDER_CANONICAL.fetch("3ctC68zTqpRDQShoondiQKDHwZDAUjRyxiPNdg8cD6Pe")))
    STRICT.encode_point(STRICT.add(STRICT.scalar_mult(clamped_scalar(seed), BASE_POINT), torsion))
  end

  # The same signature with S + L in place of S, when that still fits the three
  # top bits the library checks; nil otherwise.
  def unreduced(signature)
    s = STRICT.le_int(signature.byteslice(32, 32)) + L
    return nil if s >= (1 << 253)

    signature.byteslice(0, 32) + le_bytes(s)
  end
end
