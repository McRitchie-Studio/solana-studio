require_relative "test_helper"

# The web3 modal surface, promoted out of studio-engine.
#
# WHAT MOVED AND WHY. studio-engine is the generic house engine: every app
# bundles it, including apps that ship no chain features at all. These four
# partials are Solana-specific to the last line — a wallet picker, a wallet
# step-up card, and the two halves of Phantom's mobile deep link — so they
# belong with the Solana primitives rather than in the engine every consumer
# pays for. They keep their behaviour byte for byte; only the home changes.
#
# THE VIRTUAL PATH IS THE CONTRACT, not the file location. A consumer writes
# `render "solana_studio/modals/wallet_connect"`, and a lookup resolves that
# through the view paths its bundle contributes. So these assertions resolve by
# virtual path rather than checking File.exist? — the second is true of a file
# that no consumer can reach, which is exactly the failure worth catching.
#
# WHAT THIS GEM DOES *NOT* OWN, stated because the partials read as if it might.
# The moved markup renders three studio-engine partials by name
# (studio/modals/blocks/wallet_brand_sprite, .../card_header, and whatever the
# caller passes as its slot), paints with studio-engine's utilities (badge,
# pulse-cta, spinner) and theme role tokens, and drives studio-engine's modal
# host through $store.<store>.swap(). None of that is new coupling introduced by
# the move: solana_studio/modals/_network_mismatch already shipped on exactly
# these terms, rendering blocks/card_header and painting with bg-surface-alt and
# btn-primary. studio-engine stays a DEVELOPMENT dependency here — a runtime one
# would drag Rails into every plain-Ruby consumer, which is the whole point of
# lib/solana_studio/engine.rb's guard — so "a host that renders these also
# bundles studio-engine" is a documented requirement, not something this gem can
# enforce from inside.
class Web3ModalsTest < Minitest::Test
  LIB  = File.expand_path("../lib", __dir__)
  ROOT = File.expand_path("..", __dir__)

  # virtual path => the file that must serve it.
  MOVED = {
    "solana_studio/modals/wallet_connect" => "app/views/solana_studio/modals/_wallet_connect.html.erb",
    "solana_studio/modals/web3_step_up"   => "app/views/solana_studio/modals/_web3_step_up.html.erb",
    "solana_studio/phantom_deeplink"      => "app/views/solana_studio/_phantom_deeplink.html.erb",
    "solana_studio/deeplink_assets"       => "app/views/solana_studio/_deeplink_assets.html.erb"
  }.freeze

  def ruby(code)
    out = IO.popen([RbConfig.ruby, "-I#{LIB}", "-e", code], err: [:child, :out], &:read)
    [out.strip, $?.success?]
  end

  def source_of(virtual_path)
    File.read(File.join(ROOT, MOVED.fetch(virtual_path)))
  end

  # COMMENTS ARE PROSE AND PROSE MATCHES ANYTHING. Every structural assertion
  # below reads the file with comments removed, so a sentence describing the
  # code can never stand in for the code.
  #
  # BOTH comment surfaces, not just ERB — measured, because stripping only ERB
  # was not enough. These partials are mostly <script> blocks, and
  # _deeplink_assets opens with the JavaScript line "// NOT document.write."
  # explaining why it appends an element instead. A refute on "document.write"
  # over ERB-stripped source matched THAT SENTENCE and failed a correct file.
  # The guard was reading the explanation of the rule instead of the code
  # obeying it, which is the exact defect this method exists to prevent.
  #
  # Whole-line // comments only. A naive strip of everything after "//" eats the
  # "https://" in the tweetnacl CDN URL on the very next line, which would hide
  # real code from every assertion here.
  def code_of(virtual_path)
    source_of(virtual_path)
      .gsub(/<%#.*?%>/m, "")       # ERB comments: end at the FIRST close sequence, as the parser does
      .gsub(%r{^[ \t]*//.*$}, "")  # JavaScript line comments, anchored to the start of a line
  end

  def test_there_are_moved_partials_to_check
    # Guards the guard: an empty or renamed map would make every assertion below
    # vacuously true, which is how a move "passes" while shipping nothing.
    assert_equal 4, MOVED.size, "the moved set changed — update the assertions with it"

    MOVED.each_value do |path|
      assert_path_exists File.join(ROOT, path)
    end
  end

  def test_every_moved_partial_resolves_by_its_virtual_path
    # THE CONSUMER'S OWN MECHANISM, not a proxy for it. turf-monster resolves
    # these through an ActionView::LookupContext over its view paths; this builds
    # the same lookup over the paths THIS engine contributes and asserts each
    # virtual path finds a template. A file present but unreachable — wrong
    # directory, wrong underscore, engine not contributing app/views — fails here
    # rather than in front of a user.
    out, ok = ruby(<<~CODE)
      require "rails"
      require "action_view"
      require "solana_studio"

      paths  = SolanaStudio::Engine.paths["app/views"].existent
      lookup = ActionView::LookupContext.new(paths)

      #{MOVED.keys.inspect}.each do |virtual|
        parts  = virtual.split("/")
        prefix = parts[0..-2].join("/")
        puts lookup.find(parts.last, [prefix], true).identifier
      end
    CODE

    assert ok, "virtual-path lookup failed: #{out}"

    identifiers = out.lines.map(&:strip)
    assert_equal MOVED.size, identifiers.length

    # Each must be served BY THIS GEM. Asserted as "under the gem's own view
    # root" rather than by matching "/gems/" in the path: turf-monster's
    # test/support/resolved_wallet_picker.rb carries an explicit warning against
    # the "/gems/" form, because it makes a path checkout of this gem fail while
    # proving nothing extra. This form is install-agnostic and still exact.
    gem_views = File.join(ROOT, "app/views")
    identifiers.each do |identifier|
      assert identifier.start_with?(gem_views),
             "#{identifier} resolved outside this gem — the partial is being served by something else"
    end
  end

  def test_the_deep_link_signs_the_statement_the_engine_owns
    # THE NO-DRIFT CONTRACT, and the one thing about this move that is genuinely
    # dangerous. studio-engine's solana_sessions/phantom_callback rebuilds the
    # signed message to post for verification, so the deep link and the callback
    # must produce the SAME statement or every mobile sign-in fails. They stay in
    # step by both reading one accessor — Studio.wallet_sign_in_statement — and
    # that property survives the move only because this partial still reads it
    # rather than taking a local of its own.
    #
    # So this is deliberately NOT parameterised, and this test is what says so.
    # A well-meaning change to `local_assigns.fetch(:statement)` would decouple
    # the gem from studio-engine, read as an improvement, and silently break the
    # signature check the moment a caller passed anything.
    #
    # Anchored on the ERB OUTPUT TAG, with comments stripped: the accessor is
    # also named in this file's prose, and a substring check would match the
    # sentence describing the rule instead of the line obeying it.
    code = code_of("solana_studio/phantom_deeplink")

    assert_match(/<%=\s*Studio\.wallet_sign_in_statement\b[^%]*%>/, code,
                 "the deep link no longer emits Studio.wallet_sign_in_statement in an ERB output tag. " \
                 "studio-engine's phantom_callback rebuilds the signed message from that same accessor; " \
                 "any other source for this string breaks verification for every mobile sign-in.")
  end

  def test_the_deep_link_takes_no_statement_local
    # The other half of the rule above, asserted from the opposite side so that
    # adding a local alongside the accessor is caught too.
    code = code_of("solana_studio/phantom_deeplink")

    refute_match(/local_assigns\s*\[\s*:statement\s*\]|local_assigns\.fetch\(\s*:statement/, code,
                 "the signed statement became caller-supplied — it must come from " \
                 "Studio.wallet_sign_in_statement so it cannot drift from the callback")
  end

  def test_the_nacl_loader_appends_a_script_and_never_writes_one
    # document.write in a body script implicitly calls document.open() at
    # readyState 'complete' and BLANKS THE PAGE under a turbo Drive visit. The
    # loader is written as an append for that reason; a simplification back to
    # document.write would look tidier and break the consumer it exists for.
    code = code_of("solana_studio/deeplink_assets")

    refute_includes code, "document.write",
                    "document.write blanks the page under a turbo Drive visit — append an element instead"

    # BOTH HALVES OF THE IDEMPOTENCE GUARD, pinned separately — measured, after a
    # mutation survived. A bare `assert_includes code, "data-studio-nacl"` is
    # satisfied by EITHER occurrence, so deleting the setAttribute that STAMPS
    # the marker left the querySelector that READS it and the assertion stayed
    # green. A loader that looks for a marker it never writes re-appends tweetnacl
    # on every render, which is precisely the bug the marker exists to prevent.
    assert_includes code, "document.querySelector('script[data-studio-nacl]')",
                    "the loader no longer CHECKS for an existing tag — it will append a second copy"
    assert_includes code, "s.setAttribute('data-studio-nacl', '')",
                    "the loader no longer STAMPS the marker it checks for, so its own guard can never fire"
    assert_includes code, "typeof window.nacl !== 'undefined'",
                    "the loader no longer defers to a host that already supplies nacl"
  end
end
