require "net/http"
require "json"
require "uri"
require "openssl"
require "time"

module Solana
  class Client
    class RpcError < StandardError
      attr_reader :code
      def initialize(message, code: nil)
        @code = code
        super(message)
      end
    end

    # An answer whose HTTP status, not a JSON-RPC error, says the call failed:
    # a 429 or 5xx after the retries ran out, any other non-2xx without a
    # JSON-RPC error in its body, or a body that is not JSON at all. `code` is
    # the HTTP status, so a caller's `rescue RpcError` and `e.code == 429` keep
    # working; `status` says the same thing by name.
    class HttpError < RpcError
      alias status code
    end

    class InsecureRpcUrlError < ArgumentError; end

    MAX_RETRIES = 3
    RETRY_DELAY = 1 # seconds
    # A server's Retry-After is honoured up to this many seconds. Reads run
    # inside requests and jobs; a provider asking for a minute gets the cap,
    # and the retry budget then decides.
    MAX_RETRY_AFTER = 10
    # Up to this fraction of RETRY_DELAY is added to every wait, so callers
    # throttled together do not all come back on the same tick.
    RETRY_JITTER = 0.5
    # HTTP statuses that mean "not processed, ask again": rate limited, or the
    # provider or a gateway in front of it failed.
    RETRYABLE_HTTP_STATUSES = [429, 500, 502, 503, 504].freeze
    # How much of an unparseable body an error message carries.
    BODY_EXCERPT = 200

    DEFAULT_RPC_URL = "https://api.devnet.solana.com"

    # Hostnames where plain http:// is permitted (local testing only).
    HTTP_OK_HOSTS = %w[localhost 127.0.0.1 ::1 0.0.0.0].freeze

    def initialize(rpc_url: nil)
      @rpc_url = rpc_url || ENV.fetch("SOLANA_RPC_URL", DEFAULT_RPC_URL)
      @uri = URI.parse(@rpc_url)
      validate_rpc_scheme!
      @request_id = 0
    end

    def get_account_info(pubkey, encoding: "base64", commitment: nil)
      config = { encoding: encoding }
      config[:commitment] = commitment if commitment
      call("getAccountInfo", [pubkey, config])
    end

    def get_token_account_balance(pubkey)
      call("getTokenAccountBalance", [pubkey])
    end

    def get_latest_blockhash(commitment: "finalized")
      result = call("getLatestBlockhash", [{ commitment: commitment }])
      result.dig("value", "blockhash")
    end

    # A blockhash together with the deadline that comes with it.
    #
    # #get_latest_blockhash returns the hash alone, and that discards the one
    # number that says when a transaction built on it dies:
    # `last_valid_block_height`. Once the cluster's block height passes it, no
    # block can include the transaction. Keep it, and a caller can tell a user
    # "this expired" instead of guessing from an RPC error string.
    LatestBlockhash = Struct.new(:blockhash, :last_valid_block_height, :slot, :commitment, keyword_init: true)

    # Defaults to "confirmed", unlike #get_latest_blockhash (which stays
    # "finalized" so no existing caller changes). A finalized hash is already
    # about 32 slots (~13s) old when fetched, out of a ~150-block life.
    #
    # PAIR IT. A transaction built on a "confirmed" hash must be sent with
    # `preflight_commitment: "confirmed"` (see #send_transaction). The RPC's
    # default preflight commitment is "finalized", and a finalized bank does not
    # yet know a fresh confirmed hash, so it answers "Blockhash not found" for a
    # perfectly valid transaction. Solana::Cosign carries the commitment from
    # build to send for exactly this reason.
    def latest_blockhash(commitment: "confirmed")
      result = call("getLatestBlockhash", [{ commitment: commitment }])
      value = result && result["value"]
      unless value && value["blockhash"] && value["lastValidBlockHeight"]
        raise RpcError.new("getLatestBlockhash returned no blockhash/lastValidBlockHeight")
      end

      LatestBlockhash.new(
        blockhash: value["blockhash"],
        last_valid_block_height: Integer(value["lastValidBlockHeight"]),
        slot: result.dig("context", "slot"),
        commitment: commitment
      )
    end

    # The cluster's current block height — the number to compare against a
    # LatestBlockhash#last_valid_block_height. Block height, not slot: skipped
    # slots do not advance it.
    def get_block_height(commitment: "confirmed")
      Integer(call("getBlockHeight", [{ commitment: commitment }]))
    end

    # Whether the cluster still accepts a transaction anchored on `blockhash`.
    # Cheap enough to ask before prompting a wallet, when a rebuild is still free
    # because nothing has been signed.
    def blockhash_valid?(blockhash, commitment: "confirmed")
      result = call("isBlockhashValid", [blockhash, { commitment: commitment }])
      result.is_a?(Hash) ? result["value"] == true : result == true
    end

    def get_minimum_balance_for_rent_exemption(size)
      call("getMinimumBalanceForRentExemption", [size])
    end

    # `preflight_commitment:` is sent only when given, so every existing caller
    # keeps the RPC default ("finalized"). Pass the commitment the blockhash was
    # fetched at — see #latest_blockhash for why the two must match.
    def send_transaction(signed_tx_base64, skip_preflight: false, preflight_commitment: nil)
      opts = { encoding: "base64", skipPreflight: skip_preflight }
      opts[:preflightCommitment] = preflight_commitment if preflight_commitment
      call("sendTransaction", [signed_tx_base64, opts])
    end

    # Server-side pre-flight: run simulateTransaction against a base64 wire tx.
    # sig_verify:false lets us simulate a tx without all signatures present (or
    # without re-verifying ones that are). Returns the RPC `value` object
    # ({ "err" =>, "logs" =>, "unitsConsumed" =>, … }); `value["err"]` is nil on
    # success. Mirrors the client-side simulate the entry board used to run.
    def simulate_transaction(signed_tx_base64, sig_verify: false, replace_recent_blockhash: false, commitment: "confirmed")
      opts = {
        encoding: "base64",
        sigVerify: sig_verify,
        replaceRecentBlockhash: replace_recent_blockhash,
        commitment: commitment
      }
      result = call("simulateTransaction", [signed_tx_base64, opts])
      result&.dig("value")
    end

    def confirm_transaction(signature, commitment: "confirmed")
      call("getSignatureStatuses", [[signature], { searchTransactionHistory: true }])
    end

    def send_and_confirm(signed_tx_base64, timeout: 30, skip_preflight: false)
      signature = send_transaction(signed_tx_base64, skip_preflight: skip_preflight)

      deadline = Time.now + timeout
      loop do
        sleep 1
        result = confirm_transaction(signature)
        status = result.dig("value", 0)

        if status
          if status["err"]
            raise RpcError.new("Transaction failed: #{status['err']}")
          end
          return signature if status["confirmationStatus"] == "confirmed" || status["confirmationStatus"] == "finalized"
        end

        raise RpcError.new("Transaction confirmation timeout") if Time.now > deadline
      end
    end

    def request_airdrop(pubkey, lamports)
      call("requestAirdrop", [pubkey, lamports])
    end

    def get_balance(pubkey)
      call("getBalance", [pubkey])
    end

    def get_transaction(signature, commitment: "confirmed")
      call("getTransaction", [signature, { encoding: "json", commitment: commitment }])
    end

    def get_token_accounts_by_owner(owner_pubkey)
      call("getTokenAccountsByOwner", [
        owner_pubkey,
        { programId: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" },
        { encoding: "jsonParsed" }
      ])
    end

    private

    def call(method, params = [])
      @request_id += 1
      body = {
        jsonrpc: "2.0",
        id: @request_id,
        method: method,
        params: params
      }

      retries = 0
      begin
        response = http_post(body)
        status = http_status(response)
        # The status first: a rate limit or gateway failure often carries a
        # body that is not JSON (Helius answers 429 with "Too many requests").
        raise http_error(status, response) if RETRYABLE_HTTP_STATUSES.include?(status)

        parsed = parse_body(response, status)

        if parsed.is_a?(Hash) && parsed["error"]
          error = parsed["error"]
          raise RpcError.new(error["message"], code: error["code"])
        end
        raise http_error(status, response) if status && !(200..299).cover?(status)

        parsed["result"]
      rescue RpcError => e
        # Retry an HTTP 429/5xx, a JSON-RPC rate limit, or blockhash expiry.
        if retries < MAX_RETRIES && retryable_error?(e)
          retries += 1
          sleep retry_delay(retries, response)
          retry
        end
        raise
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET => e
        if retries < MAX_RETRIES
          retries += 1
          sleep retry_delay(retries)
          retry
        end
        raise RpcError.new("Network error: #{e.message}")
      end
    end

    # The response's HTTP status as an Integer, or nil when the transport does
    # not report one. A real Net::HTTPResponse always does; host test suites
    # stub #http_post with objects that answer #body only, and those are read
    # exactly as before.
    def http_status(response)
      return nil unless response.respond_to?(:code)

      Integer(response.code.to_s, 10)
    rescue ArgumentError
      nil
    end

    # JSON.parse, except that a body which is not JSON raises HttpError (an
    # RpcError) carrying the status, never JSON::ParserError.
    def parse_body(response, status)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise HttpError.new("RPC response is not JSON (HTTP #{status || 'status unknown'}): #{excerpt(response)}",
                          code: status)
    end

    def http_error(status, response)
      HttpError.new("HTTP #{status} from RPC: #{excerpt(response)}", code: status)
    end

    # The start of the body, safe to interpolate: an upstream error page can be
    # Latin-1 or gzip bytes (Net::HTTP hands those back as ASCII-8BIT), and
    # mixing them into a UTF-8 message raises Encoding::CompatibilityError.
    def excerpt(response)
      text = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").strip
      text.length > BODY_EXCERPT ? "#{text[0, BODY_EXCERPT]}…" : text
    end

    # The wait before retry number `attempt`: the linear backoff (1s, 2s, 3s at
    # RETRY_DELAY = 1), or the server's Retry-After when it asks for longer,
    # plus jitter.
    def retry_delay(attempt, response = nil)
      base = RETRY_DELAY * attempt
      asked = retry_after_seconds(response)
      base = asked if asked && asked > base
      base + (rand * RETRY_DELAY * RETRY_JITTER)
    end

    # Retry-After as seconds (RFC 9110: delay-seconds or an HTTP-date), capped
    # at MAX_RETRY_AFTER. nil when absent or unreadable.
    def retry_after_seconds(response)
      return nil unless response.respond_to?(:[])

      value = response["Retry-After"].to_s.strip
      return nil if value.empty?

      seconds = if value.match?(/\A\d+\z/)
                  value.to_i
                else
                  Time.httpdate(value) - Time.now
                end
      seconds.clamp(0, MAX_RETRY_AFTER)
    rescue ArgumentError
      nil
    end

    def http_post(body)
      http = Net::HTTP.new(@uri.host, @uri.port)
      if @uri.scheme == "https"
        http.use_ssl = true
        # Belt-and-suspenders: Net::HTTP defaults to VERIFY_PEER in modern Ruby
        # but a) some older builds have shipped with weaker defaults and b)
        # being explicit here protects against future regressions or downstream
        # monkey-patches.
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      end
      http.open_timeout = 10
      http.read_timeout = 30

      # `request_uri` preserves the query string (path + "?" + query).
      # `path` alone drops it, which silently breaks RPC providers that
      # carry credentials on the query — e.g. Helius:
      # `https://devnet.helius-rpc.com/?api-key=…`. The server replies
      # with `{"error":"missing api key"}` and the client retries.
      request_path = @uri.request_uri
      request = Net::HTTP::Post.new(request_path.empty? ? "/" : request_path)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      http.request(request)
    end

    def retryable_error?(error)
      return RETRYABLE_HTTP_STATUSES.include?(error.code) if error.is_a?(HttpError)
      return true if error.code == 429 # JSON-RPC rate limited
      return true if error.message.include?("Blockhash not found")
      false
    end

    # Reject plain http:// RPC URLs unless the host is local. Prevents
    # accidental cleartext communication with public RPC providers.
    def validate_rpc_scheme!
      return if @uri.scheme == "https"
      if @uri.scheme == "http" && HTTP_OK_HOSTS.include?(@uri.host.to_s.downcase)
        return
      end
      raise InsecureRpcUrlError,
            "Solana::Client requires an https:// RPC URL (got #{@rpc_url.inspect}). " \
            "Plain http:// is only allowed for localhost. Set SOLANA_RPC_URL to a " \
            "TLS endpoint (e.g. https://api.mainnet-beta.solana.com or your " \
            "paid provider's HTTPS endpoint)."
    end
  end
end
