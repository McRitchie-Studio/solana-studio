# frozen_string_literal: true

module SolanaStudio
  # THE gem's version, and the only place it is written.
  #
  # This file exists to be rewritten by the release conductor and by nothing
  # else. `bin/release prepare` allocates the number from the candidate's
  # membership and rewrites the single literal below
  # (Release::GemVersion.rewrite_version, which refuses a file declaring more
  # than one rather than guess which is real), so keep it to exactly one.
  #
  # It used to live in solana-studio.gemspec, which made the WHOLE gemspec
  # release-owned in bin/dor-check's eyes — including spec.files, the runtime
  # dependencies and the metadata, none of which the conductor touches and none
  # of which had another writer. That left the manifest permanently un-editable
  # through the normal cycle. Splitting the version out is the same shape
  # studio-engine already uses (lib/studio/version.rb) and hands each file back
  # to its real owner: this one to the release, the gemspec to the PR.
  VERSION = "0.5.3"
end
