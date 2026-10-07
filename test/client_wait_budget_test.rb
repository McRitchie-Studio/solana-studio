require_relative "test_helper"
require "logger"
require "stringio"

# Solana::Client#call has a total-wait budget.
#
# The 429/5xx retry (0.12.x Unreleased) honours Retry-After up to 10s, three
# times, plus jitter: about 31.5s of sleeping in one call. turf-monster runs
# some calls inside a web request (the navbar balance threads, entry confirm,
# cosign submits), and Heroku kills a request at 30s. The budget stops a call
# before it starts a wait that would carry its total past the line, and raises
# the last error instead.
#
# Nothing here opens a socket or sleeps: each client's transport answers from
# a script, and #sleep and #rand are recorded instead of run.
class Solana::ClientWaitBudgetTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {}).find { |k, _| k.casecmp?(name) }&.last
    end
  end

  OK_BODY = '{"jsonrpc":"2.0","id":1,"result":{"context":{"slot":7},"value":5}}'.freeze

  def ok
    FakeResponse.new("200", OK_BODY, {})
  end

  def too_many(headers = {})
    FakeResponse.new("429", "Too many requests", headers)
  end

  def scripted_client(*responses, jitter: 0.0, **client_opts)
    client = Solana::Client.new(rpc_url: "https://mainnet.helius-rpc.com/?api-key=secret-key", **client_opts)
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

  def capture_logger
    io = StringIO.new
    [Logger.new(io), io]
  end

  # --- The control: the same script with the ceiling lifted --------------------

  def test_control_without_a_ceiling_three_capped_retry_afters_sleep_past_thirty_seconds
    # The defect this budget exists for, reproduced: an unbounded budget lets
    # three Retry-After waits at the 10s cap (plus the worst jitter) run to
    # 31.5s, past Heroku's 30s. If this stops holding, the budget tests below
    # are no longer testing anything.
    client, log = scripted_client(too_many("Retry-After" => "60"), jitter: 1.0, wait_budget: Float::INFINITY)

    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_equal Solana::Client::MAX_RETRIES, log[:sleeps].size
    assert_in_delta 31.5, log[:sleeps].sum, 1e-9
    assert_operator log[:sleeps].sum, :>, 30
  end

  # --- The budget stops retries ------------------------------------------------

  def test_the_default_budget_stops_retries_before_the_total_wait_passes_it
    client, log = scripted_client(too_many("Retry-After" => "10"), jitter: 1.0)

    error = assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_equal 429, error.code
    # 10.5s fits under 15; a second 10.5s would make 21. One wait, then raise.
    assert_equal [10.5], log[:sleeps]
    assert_equal 2, log[:attempts]
    assert_operator log[:sleeps].sum, :<=, Solana::Client::DEFAULT_WAIT_BUDGET
    stats = error.call_stats
    assert_equal 1, stats.retries
    assert_equal 2, stats.attempts
    assert_in_delta 10.5, stats.waited, 1e-9
    assert stats.budget_stopped
  end

  def test_the_default_budget_is_fifteen_seconds
    assert_equal 15.0, Solana::Client::DEFAULT_WAIT_BUDGET
    assert_equal 15.0, Solana::Client.new(rpc_url: "https://example.invalid/").wait_budget
  end

  def test_linear_backoff_inside_the_budget_still_gets_every_retry
    # 1 + 2 + 3 = 6s fits the default 15s: the budget changes nothing for the
    # ordinary case, and the third retry can still succeed.
    client, log = scripted_client(too_many, too_many, too_many, ok)

    assert_equal 5, client.get_balance("Owner1")["value"]
    assert_equal [1.0, 2.0, 3.0], log[:sleeps]
    stats = client.last_call_stats
    assert_equal 3, stats.retries
    refute stats.budget_stopped
  end

  def test_a_per_client_budget_stops_retries
    client, log = scripted_client(too_many, wait_budget: 3)

    error = assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    # 1s, then 1+2 = 3s exactly fits, then +3 = 6s does not.
    assert_equal [1.0, 2.0], log[:sleeps]
    assert_equal 2, error.call_stats.retries
  end

  def test_a_zero_budget_never_retries
    client, log = scripted_client(too_many, wait_budget: 0)

    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_equal 1, log[:attempts]
    assert_empty log[:sleeps]
  end

  def test_with_wait_budget_overrides_the_client_budget_for_calls_inside_the_block
    client, log = scripted_client(too_many)

    Solana::Client.with_wait_budget(1) do
      assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }
    end

    assert_equal [1.0], log[:sleeps]
    assert_equal 1.0, client.last_call_stats.budget
  end

  def test_with_wait_budget_restores_the_outer_budget_even_when_the_block_raises
    client, _log = scripted_client(ok)

    Solana::Client.with_wait_budget(2) do
      assert_raises(RuntimeError) { Solana::Client.with_wait_budget(1) { raise "boom" } }
      client.get_balance("Owner1")
      assert_equal 2.0, client.last_call_stats.budget
    end
    client.get_balance("Owner1")
    assert_equal 15.0, client.last_call_stats.budget
  end

  def test_an_invalid_budget_is_refused_and_leaves_the_outer_budget_in_place
    assert_raises(ArgumentError) { Solana::Client.new(rpc_url: "https://example.invalid/", wait_budget: -1) }
    assert_raises(ArgumentError) { Solana::Client.new(rpc_url: "https://example.invalid/", wait_budget: "5") }
    assert_raises(ArgumentError) { Solana::Client.new(rpc_url: "https://example.invalid/", wait_budget: Float::NAN) }

    client, _log = scripted_client(ok)
    Solana::Client.with_wait_budget(2) do
      assert_raises(ArgumentError) { Solana::Client.with_wait_budget(nil) { flunk "must not run" } }
      client.get_balance("Owner1")
      assert_equal 2.0, client.last_call_stats.budget
    end
  end

  def test_the_budget_also_bounds_network_retries
    client = Solana::Client.new(rpc_url: "https://example.invalid/", wait_budget: 1)
    sleeps = []
    client.define_singleton_method(:http_post) { |_| raise Net::ReadTimeout }
    client.define_singleton_method(:sleep) { |s| sleeps << s }
    client.define_singleton_method(:rand) { |*| 0.0 }

    error = assert_raises(Solana::Client::RpcError) { client.get_balance("Owner1") }

    assert_includes error.message, "Network error"
    assert_equal [1.0], sleeps
    assert error.call_stats.budget_stopped
  end

  # --- Retry-After larger than what is left raises at once --------------------

  def test_a_retry_after_larger_than_the_remaining_budget_raises_without_sleeping
    client, log = scripted_client(too_many("Retry-After" => "8"), wait_budget: 5)

    error = assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_equal 429, error.status
    assert_empty log[:sleeps], "never sleeps part of a wait it cannot finish"
    assert_equal 1, log[:attempts]
    assert_equal 0, error.call_stats.retries
    assert error.call_stats.budget_stopped
  end

  def test_a_retry_after_larger_than_what_is_left_after_earlier_waits_raises_then
    client, log = scripted_client(too_many, too_many("Retry-After" => "9"), wait_budget: 6)

    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    # 1s first; then 1 + 9 = 10 > 6, so the second wait is never started.
    assert_equal [1.0], log[:sleeps]
    assert_equal 2, log[:attempts]
  end

  # --- The retries are visible ------------------------------------------------

  def test_each_retry_is_logged_with_its_count_and_the_total_waited
    logger, io = capture_logger
    client, _log = scripted_client(too_many, too_many, ok, logger: logger)

    client.get_balance("Owner1")

    lines = io.string.lines
    assert_equal 2, lines.size
    assert_match(%r{getBalance retry 1/3 after HttpError 429: waiting 1\.00s \(1\.00s of 15\.00s budget\)}, lines[0])
    assert_match(%r{getBalance retry 2/3 after HttpError 429: waiting 2\.00s \(3\.00s of 15\.00s budget\)}, lines[1])
  end

  def test_the_budget_stop_is_logged_with_the_retry_count_and_the_time_waited
    logger, io = capture_logger
    client, _log = scripted_client(too_many("Retry-After" => "10"), logger: logger)

    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_match(/getBalance wait budget spent after 1 retries \(10\.00s waited, next wait 10\.00s, budget 15\.00s\): raising HttpError 429/,
                 io.string.lines.last)
  end

  def test_the_log_never_carries_the_rpc_url_or_its_api_key
    logger, io = capture_logger
    client, _log = scripted_client(too_many, wait_budget: 1, logger: logger)

    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    refute_empty io.string
    refute_includes io.string, "secret-key"
    refute_includes io.string, "helius"
    refute_includes io.string, "Owner1"
  end

  def test_a_broken_logger_does_not_change_the_result
    broken = Object.new
    broken.define_singleton_method(:warn) { |_| raise IOError, "disk full" }
    client, _log = scripted_client(too_many, ok, logger: broken)

    assert_equal 5, client.get_balance("Owner1")["value"]
  end

  # The shape turf-monster's Solana::ClientLogger has: a module prepended over
  # the private #call that records after `super` returns or raises. It can
  # read the retry count and the time waited from #last_call_stats.
  module RecordingWrapper
    attr_reader :recorded

    private

    def call(method, params = [])
      super
    ensure
      stats = last_call_stats
      (@recorded ||= []) << { method: method, retries: stats&.retries, waited: stats&.waited }
    end
  end

  def test_a_prepended_logger_reads_the_retry_count_and_time_waited_on_success_and_failure
    klass = Class.new(Solana::Client) { prepend RecordingWrapper }
    client = klass.new(rpc_url: "https://example.invalid/", wait_budget: 4)
    queue = [too_many, too_many, ok, too_many("Retry-After" => "3")]
    client.define_singleton_method(:http_post) { |_| queue.size > 1 ? queue.shift : queue.first }
    client.define_singleton_method(:sleep) { |_| }
    client.define_singleton_method(:rand) { |*| 0.0 }

    client.get_balance("Owner1")
    assert_raises(Solana::Client::HttpError) { client.get_balance("Owner1") }

    assert_equal [{ method: "getBalance", retries: 2, waited: 3.0 },
                  { method: "getBalance", retries: 1, waited: 3.0 }], client.recorded
  end

  def test_last_call_stats_belongs_to_the_client_that_made_the_call
    a, _ = scripted_client(ok)
    b, _ = scripted_client(ok)

    a.get_balance("Owner1")

    refute_nil a.last_call_stats
    assert_nil b.last_call_stats, "another client's stats are not this client's"
  end

  # --- A retried sendTransaction posts the same bytes -------------------------

  def test_a_retried_send_transaction_posts_byte_identical_bodies
    # Captured below #http_post, at Net::HTTP#request: the bytes on the wire.
    # The cluster deduplicates a re-post by signature only if it IS the same
    # transaction; a retry must not re-serialize, re-number or re-sign.
    client = Solana::Client.new(rpc_url: "https://example.invalid/?api-key=k")
    client.define_singleton_method(:sleep) { |_| }
    client.define_singleton_method(:rand) { |*| 0.0 }
    bodies = []
    answers = [too_many, FakeResponse.new("503", "busy", {}), FakeResponse.new("200", '{"jsonrpc":"2.0","id":1,"result":"Sig111"}', {})]
    fake_http = Object.new
    %i[use_ssl= verify_mode= min_version= open_timeout= read_timeout=].each do |setter|
      fake_http.define_singleton_method(setter) { |_| }
    end
    fake_http.define_singleton_method(:request) do |req|
      bodies << req.body.b
      answers.shift
    end

    wire = "AQID" + ("A" * 300) + "=="
    Net::HTTP.stub :new, fake_http do
      assert_equal "Sig111", client.send_transaction(wire, preflight_commitment: "confirmed")
    end

    assert_equal 3, bodies.size
    assert_equal 1, bodies.uniq.size, "every attempt posts the identical bytes"
    assert_includes bodies.first, wire
    assert_equal "sendTransaction", JSON.parse(bodies.first)["method"]
  end
end
