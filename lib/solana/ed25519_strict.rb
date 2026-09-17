require "ed25519"

module Solana
  # Ed25519 verification with the checks the `ed25519` gem leaves out.
  #
  # `Ed25519::VerifyKey` (ref10) answers one question: does the verification
  # equation hold? It does not ask whether the public key is a key anyone could
  # hold a secret for. A small-order point — or a non-canonical spelling of one —
  # decodes, and signatures verify against it with no secret key behind them. For
  # a sign-in that means an address nobody owns can sign in.
  #
  # So before the equation runs, this module requires:
  #
  #   public key  a CANONICAL encoding (y < p, no negative zero) of a curve point
  #               that is NOT small-order and IS in the prime-order subgroup
  #               ([L]A is the identity). Every key a wallet generates is [a]B,
  #               which always passes; nothing a real user holds is refused.
  #   R           a canonical encoding of a point that is NOT small-order.
  #   S           reduced: S < L. The library only checks the top three bits,
  #               which leaves S + L as a second valid spelling.
  #
  # That is Solana's own rule (`verify_strict`: small-order A and R and an
  # unreduced S are refused) plus the subgroup check on A, which the chain does
  # not make but which no generated key can fail. A signature this module
  # accepts is one the cluster accepts too.
  #
  # Pure Ruby on Integer#pow: no new dependency. A full check costs a few
  # milliseconds, dominated by one 253-bit scalar multiplication.
  module Ed25519Strict
    PUBLIC_KEY_BYTES = 32
    SIGNATURE_BYTES = 64

    # Field prime, group order, curve constant d, and sqrt(-1) mod p.
    P = 2**255 - 19
    L = 2**252 + 27_742_317_777_372_353_535_851_937_790_883_648_493
    D = (-121_665 * 121_666.pow(P - 2, P)) % P
    D2 = (2 * D) % P
    SQRT_M1 = 2.pow((P - 1) / 4, P)

    # Extended coordinates [X, Y, Z, T], x = X/Z, y = Y/Z, xy = T/Z.
    IDENTITY = [0, 1, 1, 0].freeze

    module_function

    # nil when `bytes` is a public key a secret key can stand behind; otherwise
    # a short reason, suitable for an error message.
    def public_key_problem(bytes)
      bytes = bytes.to_s.b
      return "must be #{PUBLIC_KEY_BYTES} bytes, got #{bytes.bytesize}" unless bytes.bytesize == PUBLIC_KEY_BYTES

      point = decode_point(bytes)
      return "is not a canonical encoding of an ed25519 point" if point.nil?
      return "is a small-order ed25519 point" if small_order?(point)
      return "is not in the ed25519 prime-order subgroup" unless in_prime_order_subgroup?(point)

      nil
    end

    # nil when `bytes` is a well-formed signature (R canonical and not
    # small-order, S reduced); otherwise a short reason. Says nothing about
    # whether it verifies — that is #verify.
    def signature_problem(bytes)
      bytes = bytes.to_s.b
      return "must be #{SIGNATURE_BYTES} bytes, got #{bytes.bytesize}" unless bytes.bytesize == SIGNATURE_BYTES

      r = decode_point(bytes.byteslice(0, 32))
      return "R is not a canonical encoding of an ed25519 point" if r.nil?
      return "R is a small-order ed25519 point" if small_order?(r)
      return "S is not reduced below the group order" unless le_int(bytes.byteslice(32, 32)) < L

      nil
    end

    def valid_public_key?(bytes)
      public_key_problem(bytes).nil?
    end

    # True only when the key and signature pass the checks above AND the
    # verification equation holds. Never raises on malformed input.
    def verify(public_key, signature, message)
      public_key = public_key.to_s.b
      signature = signature.to_s.b
      return false if public_key_problem(public_key) || signature_problem(signature)

      Ed25519::VerifyKey.new(public_key).verify(signature, message)
      true
    rescue Ed25519::VerifyError, ArgumentError
      false
    end

    # RFC 8032 §5.1.3, strict: a y at or above p, a negative zero x, and a y
    # with no x on the curve all return nil.
    def decode_point(bytes)
      bytes = bytes.to_s.b
      return nil unless bytes.bytesize == PUBLIC_KEY_BYTES

      int = le_int(bytes)
      y = int & ((1 << 255) - 1)
      sign = int >> 255
      return nil if y >= P

      u = (y * y - 1) % P
      v = (D * y * y + 1) % P
      x = (u * v.pow(3, P) * (u * v.pow(7, P)).pow((P - 5) / 8, P)) % P
      vx2 = (v * x * x) % P
      if vx2 == u
        # x is a square root of u/v
      elsif vx2 == (P - u) % P
        x = (x * SQRT_M1) % P
      else
        return nil
      end
      return nil if x.zero? && sign == 1

      x = P - x if (x & 1) != sign
      [x, y, 1, (x * y) % P]
    end

    # RFC 8032 §5.1.2.
    def encode_point(point)
      x, y, z, = point
      z_inv = z.pow(P - 2, P)
      x = (x * z_inv) % P
      y = (y * z_inv) % P
      int = y | ((x & 1) << 255)
      Array.new(32) { |i| (int >> (8 * i)) & 0xff }.pack("C*")
    end

    def identity?(point)
      x, y, z, = point
      (x % P).zero? && ((y - z) % P).zero?
    end

    # [8]P is the identity: P is one of the eight points of the torsion subgroup.
    def small_order?(point)
      identity?(double(double(double(point))))
    end

    # [L]P is the identity. The identity itself passes, so callers check
    # small_order? first.
    def in_prime_order_subgroup?(point)
      identity?(scalar_mult(L, point))
    end

    # RFC 8032 §5.1.4 addition (complete for this curve).
    def add(p1, p2)
      x1, y1, z1, t1 = p1
      x2, y2, z2, t2 = p2
      a = ((y1 - x1) * (y2 - x2)) % P
      b = ((y1 + x1) * (y2 + x2)) % P
      c = (t1 * D2 % P * t2) % P
      d = (z1 * 2 * z2) % P
      e = b - a
      f = d - c
      g = d + c
      h = b + a
      [(e * f) % P, (g * h) % P, (f * g) % P, (e * h) % P]
    end

    def double(point)
      x1, y1, z1, = point
      a = (x1 * x1) % P
      b = (y1 * y1) % P
      c = (2 * z1 * z1) % P
      h = a + b
      e = h - (x1 + y1)**2
      g = a - b
      f = c + g
      [(e * f) % P, (g * h) % P, (f * g) % P, (e * h) % P]
    end

    def scalar_mult(scalar, point)
      result = IDENTITY
      (scalar.bit_length - 1).downto(0) do |i|
        result = double(result)
        result = add(result, point) if scalar[i] == 1
      end
      result
    end

    def le_int(bytes)
      bytes.unpack("C*").each_with_index.sum { |byte, i| byte << (8 * i) }
    end
  end
end
