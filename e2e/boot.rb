# frozen_string_literal: true

# e2e/boot.rb — copy the lab's assets, then serve the dummy host.
#
# Playwright's webServer runs this. It replaces the
# `bin/rails db:test:prepare && bin/rails server` chain an APP's lane uses,
# because a gem has no Rails root: no bin/rails, no config.ru, no
# config/environments, and test/dummy deliberately has none of them either.
# This script does the two jobs that remain — deliver assets, serve — which also
# means the lane never depends on a `rails` CLI resolving the right app root.
#
# NO DATABASE, and that is not a simplification to revisit later: this gem's
# onchain surface is a partial and a script whose only inputs are locals and one
# data attribute. There is no row for a spec to seed and no state for a minitest
# run to truncate underneath it. If a future lab page needs a record, it must seed
# it IN THIS PROCESS rather than reaching for a shared database.

require "bundler/setup"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
PUBLIC_DIR = File.join(ROOT, "test", "dummy", "public", "e2e")

# ---- The gem's OWN shipped JavaScript ----------------------------------------
#
# COPIED, not regenerated, and that is the point of the lane: the bytes a spec
# drives here are the bytes a consumer installs. A lab that served a re-typed copy
# would report green over a file nobody ships.
gem_js_src = File.join(ROOT, "app", "assets", "javascripts", "solana_studio")
gem_js_dst = File.join(PUBLIC_DIR, "js", "solana_studio")
FileUtils.mkdir_p(gem_js_dst)
FileUtils.cp_r(Dir.glob(File.join(gem_js_src, "*")), gem_js_dst)

# ---- studio-engine's vendored Alpine -----------------------------------------
#
# From the INSTALLED GEM, not vendored again here. The modal host's store and the
# partial's x-text bindings are Alpine programs; without it the card renders with
# every slot blank and a spec asserting "the network label is Devnet" would fail
# for a reason that has nothing to do with this gem.
engine_dir = Gem.loaded_specs["studio-engine"]&.gem_dir
abort "e2e/boot: studio-engine is not bundled — the modal host cannot load" if engine_dir.nil?

engine_js_src = File.join(engine_dir, "app", "assets", "javascripts", "studio")
abort "e2e/boot: studio-engine ships no javascripts/studio — has its layout moved?" unless Dir.exist?(engine_js_src)

engine_js_dst = File.join(PUBLIC_DIR, "js", "studio")
FileUtils.mkdir_p(engine_js_dst)
FileUtils.cp_r(Dir.glob(File.join(engine_js_src, "*")), engine_js_dst)

alpine = File.join(engine_js_dst, "alpine.js")
abort "e2e/boot: studio-engine's alpine.js did not arrive at #{alpine}" unless File.exist?(alpine)

# ---- Serve -------------------------------------------------------------------
ENV["RAILS_ENV"] ||= "test"
require_relative "../test/dummy/config/environment"

require "puma"
require "puma/server"

port = Integer(ENV.fetch("E2E_PORT", "3640"))
host = ENV.fetch("E2E_HOST", "127.0.0.1")

server = Puma::Server.new(Rails.application)
server.add_tcp_listener(host, port)

warn "e2e/boot: serving the solana-studio lab on http://#{host}:#{port}"
server.run
sleep
