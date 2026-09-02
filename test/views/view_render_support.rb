# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../dummy/config/environment", __dir__)

require "minitest/autorun"
require "action_view"
require "nokogiri"

# The RENDER tier for this gem's shipped partials.
#
# WHY THIS TIER EXISTS AT ALL, given test/web3_modals_test.rb already reads these
# same files. That suite asserts on SOURCE — it greps the ERB with comments
# stripped — and there is a whole class of contract it structurally cannot see.
# The picker's store and connect-function seams are written `$store.<%= store %>`
# and `window.<%= connect_fn %>(name, opts)`, so the strings a consumer actually
# depends on — `$store.modals.current()`, `window.solanaConnectAndVerify(name,
# opts)` — appear ZERO times in the file. Every default, every local override,
# and every escaping decision exists only after ERB runs. Likewise
# test/views_test.rb proves the templates COMPILE, and a template compiles
# perfectly while rendering wrong (the browser lane was stood up after exactly
# that: an ERB comment that terminated early and leaked `%>` into the card).
#
# WHAT MOVED AND FROM WHERE. studio-engine owned these two cards until
# /tasks/drop-engine-web3-modals deleted its copies in favour of this gem's. Its
# render-tier suites went with them, and this gem carried no equivalent, so the
# extra_data seam, the named slot, the layout-flow leak, and the announcement
# guard were left asserted by nobody. These files are that coverage, re-homed.
#
# WHAT DELIBERATELY DID NOT MOVE. studio-engine keeps its style-guide assertions
# (test/views/style_web3_specimens_test.rb) and they stay there. Re-asserting gem
# internals from the engine re-couples the repos and reddens engine CI on every
# legitimate change here; re-asserting the engine's style guide from the gem is
# the same mistake pointing the other way. Nothing below renders `style/`.
module ViewRenderSupport
  # BOTH engines, because the card is only half of what a consumer sees. The
  # picker renders `studio/modals/blocks/wallet_brand_sprite` and `card_header`
  # BY NAME, and the sprite is where `<symbol id="se-wallet-phantom">` is
  # actually defined — this gem's own source carries only the `<use>` that
  # references it. Render with the gem's paths alone and the partial raises;
  # render with a stub and the sprite assertions grade the stub.
  #
  # Derived from each engine's own `paths`, never a hardcoded gems directory.
  # test/web3_modals_test.rb documents why: matching "/gems/" makes a path
  # checkout of this gem fail while proving nothing extra.
  VIEW_PATHS = (
    SolanaStudio::Engine.paths["app/views"].existent +
    Studio::Engine.paths["app/views"].existent
  ).freeze

  # A fixture root for TEST-ONLY templates. It is a separate view path, never
  # app/views: anything under app/views ships to every consumer (see the
  # gemspec's `Dir["app/**/*"]`), and a probe layout is not a product file.
  FIXTURE_PATH = File.expand_path("fixtures/picker_layout", __dir__).freeze

  def view(extra_paths = [])
    ActionView::Base.with_empty_template_cache.with_view_paths(VIEW_PATHS + extra_paths)
  end

  # Inner HTML of a container, parsed rather than scanned.
  #
  # A HAND-ROLLED TAG SCANNER IS THE KNOWN-WRONG TOOL HERE, and this is not a
  # preference. The version studio-engine shipped first read the wallet row's
  # VOID <img> — no trailing slash, no close tag — as an OPEN element, so its
  # depth never returned to zero and it answered "one root" for ANY number of
  # roots. Offset arithmetic fails the same way from the other side: content
  # moved just PAST a root's closing tag still sits after that root's opening
  # tag, so a naive index comparison reports it as inside.
  #
  # HTML5, not HTML4: the picker's card is mostly <script> and inline SVG, and
  # the HTML5 parser is the one that agrees with the browser about both.
  def inner_html_of(html, selector)
    Nokogiri::HTML5.fragment(html).at_css(selector)&.inner_html
  end

  def element_children_count(fragment)
    Nokogiri::HTML5.fragment(fragment).element_children.length
  end
end
