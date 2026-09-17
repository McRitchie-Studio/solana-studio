require_relative "test_helper"

class Solana::ClientTest < Minitest::Test
  # The previous implementation used `@uri.path` to build the Net::HTTP
  # request, which silently dropped any query string. RPC providers that
  # carry their API key on the query — Helius, QuickNode, Triton — would
  # then receive an authless request and reject it with the upstream's
  # equivalent of "missing api key".
  def test_http_post_preserves_query_string_in_request_path
    client = Solana::Client.new(rpc_url: "https://devnet.helius-rpc.com/?api-key=test-key-123")

    # Capture the Net::HTTP::Post that http_post hands to http.request,
    # without actually opening a connection.
    captured_request = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:verify_mode=) { |_| }
    fake_http.define_singleton_method(:min_version=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) do |req|
      captured_request = req
      fake_response = Object.new
      fake_response.define_singleton_method(:body) { "{}" }
      fake_response
    end

    Net::HTTP.stub :new, fake_http do
      client.send(:http_post, { jsonrpc: "2.0", id: 1, method: "getHealth", params: [] })
    end

    refute_nil captured_request, "expected http_post to construct a request"
    # Net::HTTPGenericRequest#path returns the full request-URI string
    # (path + "?" + query), so the query must survive into the request.
    assert_equal "/?api-key=test-key-123", captured_request.path
  end

  def test_http_post_uses_root_path_when_url_has_no_path_or_query
    client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")

    captured_request = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:use_ssl=) { |_| }
    fake_http.define_singleton_method(:verify_mode=) { |_| }
    fake_http.define_singleton_method(:min_version=) { |_| }
    fake_http.define_singleton_method(:open_timeout=) { |_| }
    fake_http.define_singleton_method(:read_timeout=) { |_| }
    fake_http.define_singleton_method(:request) do |req|
      captured_request = req
      fake_response = Object.new
      fake_response.define_singleton_method(:body) { "{}" }
      fake_response
    end

    Net::HTTP.stub :new, fake_http do
      client.send(:http_post, { jsonrpc: "2.0", id: 1, method: "getHealth", params: [] })
    end

    refute_nil captured_request
    assert_equal "/", captured_request.path
  end

  def test_simulate_transaction_sends_correct_rpc_and_returns_value
    client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")

    captured_body = nil
    client.define_singleton_method(:http_post) do |body|
      captured_body = body
      resp = Object.new
      resp.define_singleton_method(:body) do
        '{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":1},' \
          '"value":{"err":null,"logs":["Program log: ok"],"unitsConsumed":4200}}}'
      end
      resp
    end

    value = client.simulate_transaction("BASE64TX", sig_verify: false)

    assert_equal "simulateTransaction", captured_body[:method]
    assert_equal "BASE64TX", captured_body[:params][0]
    assert_equal false, captured_body[:params][1][:sigVerify]
    assert_equal "base64", captured_body[:params][1][:encoding]
    assert_nil value["err"]
    assert_equal 4200, value["unitsConsumed"]
    assert_includes value["logs"], "Program log: ok"
  end

  def test_simulate_transaction_surfaces_program_error
    client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")
    client.define_singleton_method(:http_post) do |_body|
      resp = Object.new
      resp.define_singleton_method(:body) do
        '{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":1},' \
          '"value":{"err":{"InstructionError":[2,{"Custom":6001}]},"logs":[]}}}'
      end
      resp
    end

    value = client.simulate_transaction("BASE64TX")
    refute_nil value["err"]
  end

  # A client whose transport answers with `result_json` and remembers the body.
  def canned_client(result_json)
    client = Solana::Client.new(rpc_url: "https://api.devnet.solana.com")
    bodies = []
    client.define_singleton_method(:http_post) do |body|
      bodies << body
      resp = Object.new
      resp.define_singleton_method(:body) { %({"jsonrpc":"2.0","id":1,"result":#{result_json}}) }
      resp
    end
    [client, bodies]
  end

  def test_latest_blockhash_keeps_the_deadline_and_defaults_to_confirmed
    client, bodies = canned_client(
      '{"context":{"slot":321},"value":{"blockhash":"EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N","lastValidBlockHeight":3090}}'
    )
    latest = client.latest_blockhash

    assert_equal "getLatestBlockhash", bodies[0][:method]
    assert_equal [{ commitment: "confirmed" }], bodies[0][:params]
    assert_equal "EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N", latest.blockhash
    assert_equal 3090, latest.last_valid_block_height
    assert_equal 321, latest.slot
    assert_equal "confirmed", latest.commitment
  end

  def test_latest_blockhash_refuses_an_answer_without_the_deadline
    client, = canned_client('{"context":{"slot":1},"value":{"blockhash":"EkSnNWid2cvwEVnVx9aBqawnmiCNiDgp3gUdkDPTKN1N"}}')
    assert_raises(Solana::Client::RpcError) { client.latest_blockhash }
  end

  def test_get_latest_blockhash_is_unchanged_for_existing_callers
    client, bodies = canned_client('{"context":{"slot":1},"value":{"blockhash":"abc","lastValidBlockHeight":9}}')
    assert_equal "abc", client.get_latest_blockhash
    assert_equal [{ commitment: "finalized" }], bodies[0][:params]
  end

  def test_get_block_height_passes_commitment
    client, bodies = canned_client("4242")
    assert_equal 4242, client.get_block_height
    assert_equal "getBlockHeight", bodies[0][:method]
    assert_equal [{ commitment: "confirmed" }], bodies[0][:params]
  end

  def test_blockhash_valid_reads_the_value_flag
    client, bodies = canned_client('{"context":{"slot":1},"value":false}')
    refute client.blockhash_valid?("abc", commitment: "processed")
    assert_equal "isBlockhashValid", bodies[0][:method]
    assert_equal ["abc", { commitment: "processed" }], bodies[0][:params]

    client, = canned_client('{"context":{"slot":1},"value":true}')
    assert client.blockhash_valid?("abc")
  end

  # The RPC default preflight commitment is "finalized". A caller that never
  # asks must keep getting exactly the options it got before.
  def test_send_transaction_omits_preflight_commitment_unless_given
    client, bodies = canned_client('"SIG"')
    client.send_transaction("WIRE")
    assert_equal({ encoding: "base64", skipPreflight: false }, bodies[0][:params][1])

    client.send_transaction("WIRE", preflight_commitment: "confirmed")
    assert_equal({ encoding: "base64", skipPreflight: false, preflightCommitment: "confirmed" }, bodies[1][:params][1])
  end
end
