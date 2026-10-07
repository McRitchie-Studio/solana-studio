require_relative "test_helper"

# Solana::Client#call must read the HTTP status BEFORE it parses the body.
#
# Helius answers a rate limit with HTTP 429 and the plain-text body
# "Too many requests". The 0.12 client parsed that as JSON first, so it raised
# JSON::ParserError, which #call never rescued, and the read was never retried.
# On 2026-10-06 that failed 7 of contest 232's reads in turf-monster's
# production wallet backfill. Every mainnet read had the same exposure.
#
# Nothing here opens a socket: each client's transport (#http_post) answers
# from a script, and #sleep and #rand are recorded instead of run.
class Solana::ClientHttpStatusTest < Minitest::Test
  # The slice of Net::HTTPResponse #call reads: a String status code, the body,
  # and header lookup by name.
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {}).find { |k, _| k.casecmp?(name) }&.last
    end
  end

  OK_BODY = '{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":7},"value":null}}'.freeze

  def ok
    FakeResponse.new("200", OK_BODY, {})
  end

  def too_many(headers = {})
    FakeResponse.new("429", "Too many requests", headers)
  end

  # A client whose transport answers with `responses` in order (the last one
  # repeats), recording every attempt and every backoff sleep.
  def scripted_client(*responses, jitter: 0.0)
    client = Solana::Client.new(rpc_url: "https://mainnet.helius-rpc.com/?api-key=test")
    log = { attempts: 0, sleeps: [] }
    queue = responses.dup
    client.define_singleton_method(:http_post) do |_body|
      log[:attempts] += 1
      queue.size > 1 ? queue.shift : queue.first
    end
    client.define_singleton_method(:sleep) { |seconds| log[:sleeps] << seconds }
    client.define_singleton_method(:rand) { |*| jitter }
    [client, log]
  end

  # --- The control: what the old parse-first code did with this body --------

  def test_control_the_plain_text_429_body_is_not_json
    # The 0.12 client called JSON.parse(response.body) first. This is the
    # exception it raised, uncaught, for Helius's rate-limit answer.
    assert_raises(JSON::ParserError) { JSON.parse(too_many.body) }
  end

  # --- 429 -------------------------------------------------------------------

  def test_a_plain_text_429_is_retried_then_the_result_is_returned
    client, log = scripted_client(too_many, ok)

    result = client.get_account_info("Entry1111111111111111111111111111111111111")

    assert_equal({ "context" => { "slot" => 7 }, "value" => nil }, result)
    assert_equal 2, log[:attempts]
    assert_equal 1, log[:sleeps].size, "one backoff before the second attempt"
  end

  def test_a_429_on_every_attempt_raises_rpc_error_429_not_a_parser_error
    client, log = scripted_client(too_many)

    error = assert_raises(Solana::Client::RpcError) { client.get_account_info("Entry1") }

    assert_equal 429, error.code
    assert_kind_of Solana::Client::HttpError, error
    assert_equal 429, error.status
    assert_includes error.message, "HTTP 429"
    assert_includes error.message, "Too many requests"
    assert_equal Solana::Client::MAX_RETRIES + 1, log[:attempts], "the existing retry budget, no more"
    assert_equal Solana::Client::MAX_RETRIES, log[:sleeps].size
  end

  def test_backoff_grows_with_each_attempt
    client, log = scripted_client(too_many)

    assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal [1, 2, 3].map { |n| n * Solana::Client::RETRY_DELAY }, log[:sleeps]
  end

  def test_backoff_adds_jitter
    client, log = scripted_client(too_many, ok, jitter: 0.4)

    client.get_balance("W1")

    expected = Solana::Client::RETRY_DELAY * (1 + (0.4 * Solana::Client::RETRY_JITTER))
    assert_in_delta expected, log[:sleeps].first, 1e-9
  end

  def test_retry_after_in_seconds_is_honoured
    client, log = scripted_client(too_many("Retry-After" => "2"), ok)

    client.get_balance("W1")

    assert_in_delta 2.0, log[:sleeps].first, 1e-9, "waits the server's 2s, not the 1s backoff"
  end

  def test_retry_after_as_an_http_date_is_honoured
    later = (Time.now + 5).httpdate
    client, log = scripted_client(too_many("retry-after" => later), ok)

    client.get_balance("W1")

    assert_operator log[:sleeps].first, :>, 3.0
    assert_operator log[:sleeps].first, :<=, 5.0
  end

  def test_retry_after_is_capped_so_a_request_cannot_hang
    client, log = scripted_client(too_many("Retry-After" => "3600"), ok)

    client.get_balance("W1")

    assert_in_delta Solana::Client::MAX_RETRY_AFTER, log[:sleeps].first, 1e-9
  end

  def test_an_unparseable_retry_after_falls_back_to_the_backoff
    client, log = scripted_client(too_many("Retry-After" => "soon"), ok)

    client.get_balance("W1")

    assert_in_delta Solana::Client::RETRY_DELAY, log[:sleeps].first, 1e-9
  end

  def test_a_json_rpc_429_inside_http_200_still_retries
    rpc_429 = FakeResponse.new("200", '{"jsonrpc":"2.0","id":1,"error":{"code":429,"message":"rate limited"}}', {})
    client, log = scripted_client(rpc_429, ok)

    client.get_balance("W1")

    assert_equal 2, log[:attempts]
  end

  # --- 5xx -------------------------------------------------------------------

  def test_a_5xx_is_retried_then_the_result_is_returned
    client, log = scripted_client(FakeResponse.new("503", "Service Unavailable", {}), ok)

    result = client.get_account_info("Entry1")

    assert_nil result["value"]
    assert_equal 2, log[:attempts]
  end

  def test_a_5xx_on_every_attempt_raises_rpc_error_with_the_http_status
    client, log = scripted_client(FakeResponse.new("502", "<html>Bad Gateway</html>", {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_account_info("Entry1") }

    assert_equal 502, error.code
    assert_equal Solana::Client::MAX_RETRIES + 1, log[:attempts]
  end

  def test_a_503_retry_after_is_honoured
    client, log = scripted_client(FakeResponse.new("503", "busy", { "Retry-After" => "4" }), ok)

    client.get_balance("W1")

    assert_in_delta 4.0, log[:sleeps].first, 1e-9
  end

  def test_a_5xx_carrying_a_json_rpc_error_is_still_retried_on_its_status
    # The status decides before the body: a gateway 500 wrapping a JSON-RPC
    # "Internal error" is a provider failure, so it retries like any other 5xx.
    body = '{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error"}}'
    client, log = scripted_client(FakeResponse.new("500", body, {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal 500, error.code
    assert_equal Solana::Client::MAX_RETRIES + 1, log[:attempts]
  end

  # --- Other statuses do not retry ---------------------------------------------

  def test_a_plain_text_400_raises_rpc_error_400_without_retrying
    client, log = scripted_client(FakeResponse.new("400", "Bad Request", {}), ok)

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal 400, error.code
    assert_equal 1, log[:attempts]
    assert_empty log[:sleeps]
  end

  def test_a_401_does_not_retry
    client, log = scripted_client(FakeResponse.new("401", "Unauthorized", {}), ok)

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal 401, error.code
    assert_equal 1, log[:attempts]
  end

  def test_a_json_rpc_error_carried_on_a_400_keeps_its_rpc_code
    # Some providers send a JSON-RPC error with a 4xx status. The client read the
    # body's error before, and still does, so its code and message survive.
    body = '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}'
    client, log = scripted_client(FakeResponse.new("400", body, {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal(-32_602, error.code)
    assert_equal "Invalid params", error.message
    refute_kind_of Solana::Client::HttpError, error
    assert_equal 1, log[:attempts]
  end

  def test_a_non_2xx_json_body_without_an_rpc_error_raises_instead_of_returning_nil
    # A 404 from a misrouted URL can be JSON with no "error" key. Reading its
    # "result" would hand the caller nil, which reads as "account not found".
    client, log = scripted_client(FakeResponse.new("404", '{"message":"route not found"}', {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_account_info("Entry1") }

    assert_equal 404, error.code
    assert_equal 1, log[:attempts]
  end

  def test_a_non_json_200_raises_rpc_error_not_a_parser_error
    client, log = scripted_client(FakeResponse.new("200", "<html>maintenance</html>", {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_equal 200, error.code
    assert_includes error.message, "not JSON"
    assert_equal 1, log[:attempts]
  end

  def test_a_long_body_is_truncated_in_the_message
    client, = scripted_client(FakeResponse.new("400", "x" * 5_000, {}))

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("W1") }

    assert_operator error.message.length, :<, 400
  end

  # --- Transports that report no status ------------------------------------------

  def test_a_transport_without_a_status_is_parsed_as_before
    # Host test suites stub #http_post with an object that answers #body only.
    # Those stubs must keep working.
    client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")
    client.define_singleton_method(:http_post) do |_body|
      resp = Object.new
      resp.define_singleton_method(:body) { '{"jsonrpc":"2.0","id":1,"result":42}' }
      resp
    end

    assert_equal 42, client.get_balance("W1")
  end
end
