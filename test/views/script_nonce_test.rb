# frozen_string_literal: true

require_relative "view_render_support"

# [unit] The two partials that render an inline script carry the request's CSP
# nonce, so they run on a host whose script-src drops 'unsafe-inline' for a
# nonce (turf-monster's signing pages). A host with no nonce generator, or a
# render outside a controller, gets no nonce attribute at all.
class ScriptNonceTest < Minitest::Test
  include ViewRenderSupport

  PARTIALS = %w[solana_studio/phantom_deeplink solana_studio/deeplink_assets].freeze

  def scripts(nonce)
    PARTIALS.to_h do |partial|
      context = view
      context.define_singleton_method(:content_security_policy_nonce) { nonce } unless nonce == :none
      [ partial, Nokogiri::HTML5.fragment(context.render(partial: partial)).css("script").reject { |s| s["src"] } ]
    end
  end

  def test_each_inline_script_carries_the_request_nonce
    scripts("partial-nonce").each do |partial, found|
      assert_equal 1, found.size, partial
      assert_equal "partial-nonce", found.first["nonce"], partial
    end
  end

  def test_no_nonce_attribute_without_a_nonce
    [ nil, :none ].each do |nonce|
      scripts(nonce).each do |partial, found|
        assert_equal 1, found.size, partial
        assert_nil found.first["nonce"], "#{partial} (#{nonce.inspect})"
      end
    end
  end
end
