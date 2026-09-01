require_relative "test_helper"
require "tmpdir"
require "fileutils"

# [unit] No ERB comment in a shipped view may terminate early and leak its tail.
#
# THE DEFECT. An ERB comment `<%#  %>` ends at the FIRST close sequence inside
# it. A comment that quotes an ERB tag therefore stops there, and everything
# after it renders into the page as visible prose. Nothing about the source looks
# wrong; the page simply grows a sentence.
#
# WHY A GEM NEEDS THIS MORE THAN AN APP DOES. These views are shipped by the gem
# and rendered by EVERY consuming app. One leaked comment here renders that prose
# in all of them at once, and no consumer can fix it locally — the fix has to be
# a gem release. This gem's suite never renders these templates either (see
# views_test.rb, which compiles but does not render), so the first thing that
# would ever see the leaked prose is a user's browser.
#
# PORTED, not reinvented, from studio-engine's test/views/erb_comment_leak_test.rb
# — which carries the measured rationale for all three signatures — because the
# four comment-dense partials this guard now covers MOVED out of that engine's
# app/views into this gem, and left the engine guard's glob when they did. The
# lesson the hub's own ci.yml states is exactly this one: "a lane that
# CONSTITUTES a verdict must be enrolled on the day it is wired, or the next lane
# repeats the bug one file over." Here it would have been one REPO over.
#
# ADAPTED TO A RAILS-FREE SUITE. There is no dummy app, no ActiveSupport::TestCase
# and no `test "..." do` macro in this gem; the whole suite is `minitest/autorun`
# plus the library. The matcher was already plain Ruby over file text, so nothing
# but the harness changed.
#
# MEASURED before shipping, on this gem's views at this commit: all three
# signatures return ZERO candidates across the 21 ERB comments in this gem's 5
# view files, so this lands green and needs no allowlist. An earlier attempt at a
# broader rule in turf-monster was defeated by 3 false positives and an
# allowlist; this shape has none.
#
# WHAT IT STILL DOES NOT CATCH, stated because a guard that overstates its reach
# is worse than a narrow one: a comment whose tail carries NO second close
# sequence at all — `<%# a note %> and then some prose` with no `%>` after it.
# That prose really does render, but it is textually indistinguishable from the
# ordinary markup that follows almost every comment in a view, which is the
# measurement that killed the broad widening twice upstream. Catching it needs an
# allowlist, and an allowlisted guard is how a rule stops guarding.
#
# AND IT GUARDS ONE COMMENT FORM, NOT ONE FILE. A green run here is not clearance
# for a whole view. The JavaScript comments inside these views' <script> blocks
# are a separate surface with a WORSE mechanism: a tag quoted inside an ERB
# comment is inert, because the comment swallows it, but a tag quoted inside a
# JavaScript comment is not inside anything ERB knows about, so ERB opens it there
# and RUNS it. Two files here ship such a block — solana_studio/_deeplink_assets
# and solana_studio/_phantom_deeplink. studio-engine guards that surface with
# test/views/script_comment_leak_test.rb; this gem does not yet, and that is a
# known gap, not a covered one.
class ErbCommentLeakTest < Minitest::Test
  COMMENT = /<%#(.*?)%>/m
  ERB_OPEN = "<%"
  ORPHAN_CLOSE = "%>"

  # The gem's own shipped view root, resolved from this file so the guard follows
  # the tree it is checked into rather than a working directory.
  VIEW_ROOT = File.expand_path("../app/views", __dir__).freeze

  def views(root = VIEW_ROOT)
    Dir.glob(File.join(root, "**", "*.erb"))
  end

  def rel(path, root)
    path.delete_prefix("#{root}/")
  end

  # SIGNATURE 1 — the comment quotes an ERB OPEN tag.
  def quoting_comments(root = VIEW_ROOT)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        next unless match[1].include?(ERB_OPEN)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  # SIGNATURE 2 — the comment quotes only a CLOSE sequence, so no open tag is
  # involved and signature 1 is blind to it. Walk forward from a comment's real
  # close, STEPPING OVER complete ERB tags, and report the first close sequence
  # that has no open of its own. That orphan is the author's second `%>` — the
  # tell that one comment became two. Legitimate trailing markup never carries one.
  #
  # THE STEP-OVER IS NOT DECORATION. The first upstream version stopped at the
  # next ERB open and searched only the text before it, which a THIRD leak shape
  # walks straight through: when the leaked tail itself REOPENS ERB before the
  # author's second close, that tag's open arrives first, so the orphan is never
  # reached and both narrow signatures stay green while the prose renders. Proven
  # upstream, not theorised — `<%# closed with %> like so, see <%= 1 %> and the
  # rest %>` renders " like so, see 1 and the rest %>" into the page.
  def orphan_close_after?(rest)
    pos = 0
    loop do
      open_at = rest.index(ERB_OPEN, pos)
      close_at = rest.index(ORPHAN_CLOSE, pos)
      return false if close_at.nil?
      return true if open_at.nil? || close_at < open_at

      # A COMPLETE tag stands between here and any orphan: skip past its own close
      # and keep looking. Stopping here is exactly the third shape's escape route.
      tag_close = rest.index(ORPHAN_CLOSE, open_at + ERB_OPEN.length)
      return false if tag_close.nil?

      pos = tag_close + ORPHAN_CLOSE.length
    end
  end

  def leaking_comments(root = VIEW_ROOT)
    views(root).flat_map do |path|
      src = File.read(path)
      src.to_enum(:scan, COMMENT).map { Regexp.last_match }.filter_map do |match|
        rest = src[match.end(0)..] || ""
        next unless orphan_close_after?(rest)

        "#{rel(path, root)}:#{src[0...match.begin(0)].count("\n") + 1}"
      end
    end.sort
  end

  def test_no_shipped_view_comment_quotes_an_erb_tag
    found = quoting_comments

    assert_empty found,
                 "these ERB comments contain an ERB open tag, so the comment TERMINATES on it " \
                 "and the rest of the prose renders into every consuming app as visible text. " \
                 "Describe the tag in words, or use an HTML comment:\n  #{found.join("\n  ")}"
  end

  def test_no_shipped_view_comment_terminates_early_and_leaks_its_tail
    found = leaking_comments

    assert_empty found,
                 "these ERB comments quote a CLOSE sequence, so the comment ends there and the " \
                 "rest of the sentence renders as visible text. No ERB open is involved, which " \
                 "is why the first assertion cannot see it:\n  #{found.join("\n  ")}"
  end

  # GUARD THE GUARDS. Without these the two assertions above are green lights that
  # can never turn red — a matcher that stopped matching reads as a clean tree,
  # which is the failure mode this whole file exists to prevent one level down.
  # The probe tree is a throwaway directory, so it exercises the SAME code paths
  # against known-bad input without depending on this gem ever shipping a leak.

  def test_the_scan_recognises_an_erb_tag_quoted_inside_a_comment
    with_probe_tree do |root|
      assert_includes quoting_comments(root).join, "_leak_open.html.erb",
                      "the matcher no longer sees the very thing it exists to catch"
      refute_includes quoting_comments(root).join, "_ok.html.erb",
                      "an ordinary comment was reported — this guard would cry wolf"
    end
  end

  def test_the_scan_recognises_a_comment_that_quotes_only_the_close_sequence
    with_probe_tree do |root|
      assert_includes leaking_comments(root).join, "_leak_close.html.erb"
      refute_includes leaking_comments(root).join, "_ok.html.erb",
                      "a plain percent in prose was reported as a leak"
    end
  end

  # All three leak shapes are asserted TOGETHER on purpose: the widened signature
  # must catch the reopening shape WITHOUT losing either of the two narrower ones
  # it inherited, and must leave ordinary views alone without an allowlist. A
  # matcher that quietly narrowed back would otherwise read as a clean tree.
  def test_the_scan_catches_all_three_leak_shapes_and_leaves_ordinary_views_alone
    with_probe_tree do |root|
      found = leaking_comments(root)

      assert_includes found.join, "_leak_reopen.html.erb",
                      "the third shape is the one the widening exists for: the leaked tail " \
                      "reopens ERB, so the author's orphan close is never the first thing " \
                      "after the comment and a narrow scan stops short of it"
      assert_includes found.join, "_leak_close.html.erb",
                      "the widening must not lose the close-only shape it inherited"
      assert_includes found.join, "_leak_open.html.erb",
                      "a quoted ERB open leaves an orphan too, and this scan must still see it"
      assert_equal 3, found.size,
                   "the scan flagged an ordinary view — an allowlist would be the next step, " \
                   "and an allowlisted guard is how a rule stops guarding. Got: #{found.inspect}"
    end
  end

  def test_there_are_views_to_check
    # Guards the guard, the same way views_test.rb does: a glob that silently
    # matched nothing would make both verdicts above vacuously true, and this
    # gem's view tree is small enough that one bad path expression empties it.
    refute_empty views,
                 "no ERB templates found under #{VIEW_ROOT} — has app/views moved? " \
                 "An empty glob makes this guard report green on everything"
  end

  private

  def with_probe_tree
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "probe"))
      File.write(File.join(dir, "probe/_leak_open.html.erb"),
                 "<div>\n  <%# quoting <%= yield %> breaks this comment %>\n</div>\n")
      # The reviewer's own case: documenting the rule leaks the explanation.
      File.write(File.join(dir, "probe/_leak_close.html.erb"),
                 "<div>\n  <%# a comment ends at the first close sequence, which is %> and " \
                 "everything after renders %>\n</div>\n")
      File.write(File.join(dir, "probe/_ok.html.erb"),
                 "<div>\n  <%# an ordinary comment %>\n  <p>50% wide</p>\n</div>\n")
      # SHAPE 3 — the tail REOPENS ERB before the author's second close, so the
      # orphan is not the first thing after the comment and a narrow scan stops
      # short of it. Rails renders " like so, see 1 and the rest %>" into the page.
      File.write(File.join(dir, "probe/_leak_reopen.html.erb"),
                 "<div>\n  <%# closed with %> like so, see <%= 1 %> and the rest %>\n</div>\n")
      # The two legitimate shapes that must stay quiet: a comment followed by a
      # real tag, and a comment followed by several. An allowlisted guard is how a
      # rule stops guarding, so these carry its cost.
      File.write(File.join(dir, "probe/_ok_tag.html.erb"),
                 "<div>\n  <%# describes the next line %>\n  <%= render \"x\" %>\n  <p>done</p>\n</div>\n")
      File.write(File.join(dir, "probe/_ok_many.html.erb"),
                 "<div>\n  <%# note %>\n  <span><%= a %></span>\n  <span><%= b %></span>\n</div>\n")
      yield dir
    end
  end
end
