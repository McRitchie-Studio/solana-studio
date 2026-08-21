require_relative "test_helper"
# ActionView, NOT stdlib ERB. Rails compiles templates with its own Erubi
# subclass, and the difference is not cosmetic: stdlib ERB cannot compile the
# block form `<%= render ... do %>` that every one of these templates uses, so a
# stdlib check would fail on correct templates and teach us to ignore it.
# Compiling with the SAME compiler the consumer will use is the only version of
# this test worth having. (Requiring action_view does not define Rails::Engine,
# so the Rails-free suite stays Rails-free.)
require "action_view"

# The shipped ERB templates.
#
# A syntax error in a gem-shipped partial cannot fail anywhere useful: this
# gem's suite never renders it, CI never renders it, and the release sweep
# publishes on membership. The first thing that evaluates the template is a
# consumer app, at runtime, in front of a user. So the compile step happens
# here, cheaply, at the only point before publish where it can go red.
#
# This asserts the template COMPILES, not that it renders correctly — rendering
# needs studio-engine's modal blocks and a Rails view context, which is the
# consumer's test to write. Compiling is what this side can honestly claim.
class ViewsTest < Minitest::Test
  VIEWS = Dir[File.expand_path("../app/views/**/*.erb", __dir__)].freeze

  def test_there_are_views_to_check
    # Guards the guard: a glob that silently matches nothing would make every
    # assertion below vacuously true.
    refute_empty VIEWS, "no ERB templates found — has app/views moved?"
  end

  def test_every_shipped_template_compiles
    VIEWS.each do |path|
      src = ActionView::Template::Handlers::ERB::Erubi.new(File.read(path)).src

      begin
        # ruby -c equivalent, in-process: raises SyntaxError on bad output.
        RubyVM::InstructionSequence.compile(src)
      rescue SyntaxError => e
        flunk "#{path} does not compile:\n#{e.message}"
      end
    end
  end

  def test_the_mismatch_modal_never_hides_the_wallets_own_error
    # A behavioral contract expressed in the template: the original wallet
    # message must be rendered. The whole design rests on the hint sitting
    # BESIDE the real error rather than replacing it, and a well-meaning
    # simplification that dropped this block would quietly invert that.
    modal = File.read(File.expand_path("../app/views/solana_studio/modals/_network_mismatch.html.erb", __dir__))

    assert_includes modal, "props.originalMessage",
                    "the modal must render the wallet's own error text"
  end
end
