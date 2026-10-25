# frozen_string_literal: true

require_relative "view_render_support"
require "json"
require "tempfile"
require "open3"
require "digest"
require "base64"

# [unit] Every remote script this gem's views load carries a sha384 integrity
# and crossorigin="anonymous", so a CDN that serves different bytes for the
# pinned URL is refused by the browser instead of run on the signing path.
#
# WHY THE SCRIPT IS EXECUTED, NOT GREPPED. solana_studio/deeplink_assets does
# not write a <script src> tag; its inline script builds the element at run time
# (document.write blanks the page under Turbo, see the partial). A rendered-HTML
# parse sees no src at all, and a source grep would pass with the integrity line
# commented out or assigned to the wrong element. So the RENDERED inline script
# runs under node against a stub document, and the assertions read the element
# it actually appends.
#
# The pinned value was recomputed on 2026-10-24 with
# `curl -sSfL <URL> | openssl dgst -sha384 -binary | openssl base64 -A`
# against the live jsDelivr file, and matched the nacl-fast.min.js inside the
# npm tarball tweetnacl-1.0.3.tgz.
# test_installed_tweetnacl_hashes_to_the_pinned_sri re-derives it offline on every run.
class RemoteScriptIntegrityTest < Minitest::Test
  include ViewRenderSupport

  ROOT = File.expand_path("../..", __dir__)
  VIEWS = File.join(ROOT, "app/views")

  NACL_URL = "https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js"
  NACL_SRI = "sha384-05+sicyRJQ56XpL4U9HJ8YbtSzFDvAg7apPKOGV6A0JsAJKFM68jp5oLnUjG5mEp"

  # Every remote .js URL anywhere under app/views, and the partial that loads it.
  # A new one fails test_every_remote_script_in_the_views_is_covered until it is
  # added here, which puts it under the integrity assertions below.
  COVERED = { NACL_URL => "solana_studio/deeplink_assets" }.freeze

  def self.node?
    @node ||= system("node --version > /dev/null 2>&1")
  end

  def setup
    # FAILS rather than skips: bin/release-check rejects a skipped file, and a
    # skipped JS lane is lost coverage that reads as green.
    assert self.class.node?, "node is required to run this suite (install node)"
  end

  def inline_script(partial)
    scripts = Nokogiri::HTML5.fragment(view.render(partial: partial)).css("script").reject { |s| s["src"] }
    assert_equal 1, scripts.size, "#{partial}: expected one inline script"
    scripts.first.text
  end

  # Runs the partial's inline script against a stub DOM and returns every
  # element it appended, with the properties and attributes it set.
  def appended_scripts(partial, nacl_present: false)
    harness = <<~JS
      var appended = [];
      function makeEl(tag) {
        var el = { tagName: tag.toUpperCase(), attrs: {} };
        el.setAttribute = function (k, v) { this.attrs[k] = String(v); };
        return el;
      }
      global.window = global;
      #{nacl_present ? "window.nacl = {};" : ""}
      global.document = {
        querySelector: function () { return null; },
        createElement: makeEl,
        head: { appendChild: function (el) { appended.push(el); } },
        body: { appendChild: function (el) { appended.push(el); } }
      };
      #{inline_script(partial)}
      console.log(JSON.stringify(appended.map(function (el) {
        return { tag: el.tagName, src: el.src, integrity: el.integrity,
                 crossOrigin: el.crossOrigin, attrs: el.attrs };
      })));
    JS
    Tempfile.create(["remote_script_integrity", ".js"]) do |f|
      f.write(harness)
      f.flush
      out, err, status = Open3.capture3("node", f.path)
      assert status.success?, "node failed: #{err}"
      JSON.parse(out)
    end
  end

  def test_tweetnacl_tag_carries_the_pinned_sha384_and_crossorigin
    found = appended_scripts("solana_studio/deeplink_assets")
    assert_equal 1, found.size, "deeplink_assets should append exactly one script"
    tag = found.first
    assert_equal "SCRIPT", tag["tag"]
    assert_equal NACL_URL, tag["src"]
    assert_equal NACL_SRI, tag["integrity"], "tweetnacl lost or changed its integrity pin"
    assert_equal "anonymous", tag["crossOrigin"], "an SRI check on a cross-origin script needs crossorigin=anonymous"
  end

  def test_every_appended_remote_script_is_pinned
    COVERED.values.uniq.each do |partial|
      appended_scripts(partial).each do |tag|
        next unless tag["src"].to_s.start_with?("http")

        assert_match(/\Asha384-[A-Za-z0-9+\/]{64}\z/, tag["integrity"].to_s, "#{partial}: #{tag['src']} has no sha384 integrity")
        assert_equal "anonymous", tag["crossOrigin"], "#{partial}: #{tag['src']} has no crossorigin"
      end
    end
  end

  # Control: the idempotence guard still holds, so the pin assertions above are
  # reading a real append rather than one the stub forced.
  def test_appends_nothing_when_the_host_already_supplies_nacl
    assert_empty appended_scripts("solana_studio/deeplink_assets", nacl_present: true)
  end

  # The node lane (test/*_js_test.rb, e2e/boot.rb) runs node_modules' tweetnacl
  # while production runs the CDN file, so both must be the same release. The
  # expected version is READ from package.json, never copied here, and must be an
  # exact version: a caret range would let `npm install` drift away from the CDN.
  def test_package_json_pins_the_cdn_tweetnacl_version_exactly
    spec = JSON.parse(File.read(File.join(ROOT, "package.json"))).dig("devDependencies", "tweetnacl")
    assert_match(/\A\d+\.\d+\.\d+\z/, spec.to_s, "package.json tweetnacl must be an exact version, not #{spec.inspect}")
    cdn_version = NACL_URL[%r{/tweetnacl@([^/]+)/}, 1]
    assert_equal spec, cdn_version, "package.json tweetnacl and the deeplink_assets CDN URL disagree"
  end

  # The bytes npm installs from the lockfile (sha512-checked by npm ci) are the
  # bytes the SRI pins. FAILS rather than skips without node_modules.
  def test_installed_tweetnacl_hashes_to_the_pinned_sri
    file = File.join(ROOT, "node_modules/tweetnacl/nacl-fast.min.js")
    assert File.exist?(file), "tweetnacl is not installed - run `npm ci` in the gem root"
    assert_equal NACL_SRI, "sha384-#{Base64.strict_encode64(Digest::SHA384.digest(File.binread(file)))}"
  end

  def test_every_remote_script_in_the_views_is_covered
    found = Dir[File.join(VIEWS, "**/*.erb")].flat_map do |path|
      File.read(path).scan(%r{https?://[^\s'"<>`]+\.m?js\b}).map { |url| [url, path.delete_prefix("#{ROOT}/")] }
    end
    uncovered = found.reject { |url, _| COVERED.key?(url) }
    assert_empty uncovered, "remote script(s) in app/views with no integrity coverage: #{uncovered.inspect}"
    assert_equal COVERED.keys.sort, found.map(&:first).uniq.sort, "a covered URL no longer appears in the views"
  end
end
