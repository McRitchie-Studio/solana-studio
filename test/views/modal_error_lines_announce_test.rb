# frozen_string_literal: true

require "minitest/autorun"

# [unit] A modal error line must ANNOUNCE.
#
# THE DEFECT THIS PINS. Modal error text carried no `role="alert"` and no
# `aria-live`, so a failure announced NOTHING to assistive tech: the user
# presses a button, the operation fails, red text appears, and as far as a
# screen reader is concerned the page did not change. It was never one card's
# slip — every inline error line in the tree matched at once.
#
# WHY `role="alert"` AND NOT `aria-live="polite"`. These lines are the direct
# result of an action the user just took, and they need to interrupt rather than
# queue behind whatever else is speaking. `role="alert"` carries an implicit
# assertive live region, which is the standard pairing.
#
# WHY IT WORKS. Every one of these lines is filled by Alpine `x-text` and is
# EMPTY when the modal opens, so the announcement fires on the CONTENT CHANGE —
# the moment the error arrives. The host renders modal content through a
# `<template x-if>`, so the element enters the DOM with the modal and is live by
# the time the failure lands.
#
# WHY THIS GUARD LIVES HERE NOW. It was studio-engine's, and it counted these
# two cards among its error lines — its floor dropped from 10 to 8 when
# /tasks/drop-engine-web3-modals moved them to this gem. Both partials still
# carry `role="alert"`, and until this file landed NOTHING in this repo asserted
# it.
#
# WHY A SOURCE SCAN AND NOT A RENDER. The two cards are each render-asserted in
# their own file, individually and by name. The job THIS file does is the one
# those cannot: it is a GLOB, so a modal partial added to this gem tomorrow — one
# no render test has been written for yet — is covered the moment it lands. A
# guard is only ever as wide as its glob, which is why the floor below exists.
class ModalErrorLinesAnnounceTest < Minitest::Test
  MODAL_DIR = File.expand_path("../../app/views/solana_studio/modals", __dir__)

  # An error line, as it actually appears in this tree: a <p> carrying a
  # `text-red-*` utility. Scoped to <p> ON PURPOSE — the same utility appears on
  # an <svg> stroke in the engine's blocks/_card_header, which is an ICON and
  # has nothing to announce.
  ERROR_PARAGRAPH = /<p\b[^>]*\bclass\s*=\s*"[^"]*\btext-red-\d+\b[^"]*"[^>]*>/m
  ANNOUNCES = /\brole\s*=\s*"alert"|\baria-live\s*=\s*"(?:polite|assertive)"/

  # The number of error lines this gem's modals carry today: one in the connect
  # picker, one in the step-up card.
  #
  # THE FLOOR IS THE POINT, not bookkeeping. Every assertion below is over a
  # SCAN, and a scan that matches nothing reports perfect compliance — a renamed
  # directory, a restructured error line, or a regex that stopped matching all
  # read as "zero silent lines" and stay green forever. Upstream this guard
  # shipped scanning one directory while three silent lines sat in a second one,
  # and only its render-level sibling caught them. Lower this number when a line
  # legitimately goes away, and only then.
  EXPECTED_ERROR_LINES = 2

  # ERB TAGS ARE NEUTRALISED FIRST, and that is not tidiness. An attribute like
  # `x-show="<%= error_model %>"` contains a `>` inside its `%>`, which
  # terminates the `[^>]*` in any tag pattern — upstream that made a whole
  # partial INVISIBLE to the first version of this scan, so it reported a
  # smaller set than exists and would have missed a silent line in exactly the
  # files that interpolate.
  #
  # COMMENTS GO FIRST AND SEPARATELY: an ERB comment ends at its FIRST `%>`,
  # exactly as the parser reads it, so it cannot be folded into the general tag
  # rule below.
  def strip_erb(source)
    source.gsub(/<%#.*?%>/m, "").gsub(/<%.*?%>/m, "ERB")
  end

  def error_paragraphs(source)
    strip_erb(source).scan(ERROR_PARAGRAPH)
  end

  def modal_views
    Dir.glob(File.join(MODAL_DIR, "**", "*.erb")).sort
  end

  def test_there_are_modal_views_to_scan
    refute_empty modal_views, "no modal templates found — has app/views/solana_studio/modals moved?"
  end

  def test_the_scan_still_finds_every_error_line_it_is_meant_to_grade
    found = modal_views.sum { |path| error_paragraphs(File.read(path)).length }

    assert_equal EXPECTED_ERROR_LINES, found,
                 "the scan graded #{found} error line(s), expected #{EXPECTED_ERROR_LINES}. " \
                 "If a line was legitimately added or removed, update EXPECTED_ERROR_LINES. " \
                 "If it was not, this regex has stopped seeing the markup and every " \
                 "assertion in this file is now vacuous."
  end

  def test_the_scan_can_actually_see_a_silent_line
    # THE CONTROL. The assertion below reports "nothing silent", which is also
    # what a broken regex, a bad strip, and an empty glob all report. So the
    # pattern is shown catching a line it is supposed to catch, and shown
    # clearing the same line once it announces.
    silent = %(<p class="text-red-400 text-sm mt-3" x-text="error">)
    announcing = %(<p role="alert" class="text-red-400 text-sm mt-3" x-text="error">)

    assert_equal 1, error_paragraphs(silent).length, "the pattern must match a bare error line"
    refute_match ANNOUNCES, error_paragraphs(silent).first
    assert_match ANNOUNCES, error_paragraphs(announcing).first

    # ...and it must still see the line when an ERB tag sits inside the element,
    # which is the shape that defeated the first version of this scan.
    interpolated = %(<p class="text-red-400" x-show="<%= error_model %>" x-text="error">)
    assert_equal 1, error_paragraphs(interpolated).length,
                 "an ERB tag inside the element must not hide it from the scan"
  end

  def test_every_modal_error_line_announces_to_a_screen_reader
    silent = {}

    modal_views.each do |path|
      offenders = error_paragraphs(File.read(path)).reject { |tag| tag.match?(ANNOUNCES) }
      silent[File.basename(path)] = offenders if offenders.any?
    end

    assert_empty silent,
                 "these modal error lines announce NOTHING to a screen reader: #{silent.inspect}. " \
                 "The user acts, the operation fails, and assistive tech reports no change at all. " \
                 "Add role=\"alert\" to the element that carries the message."
  end
end
