# frozen_string_literal: true

require_relative "../test_helper"
require "libtmux"

class CapabilitiesTest < Minitest::Test
  REGISTRY = LibTmux::Internal::Capabilities
  CAPABILITIES = REGISTRY::CAPABILITIES
  WORKAROUNDS = REGISTRY::WORKAROUNDS
  MANIFEST = File.expand_path("../../capabilities.json", __dir__)

  def release(text) = LibTmux::Internal::TmuxVersion.parse(text)

  def test_the_committed_manifest_is_the_registry
    assert_equal REGISTRY.manifest_json, File.read(MANIFEST), "run scripts/emit-capabilities"
  end

  def test_the_manifest_names_the_floor_and_has_unique_ids
    manifest = JSON.parse(File.read(MANIFEST))
    assert_equal "libtmux-capabilities/1", manifest.fetch("schema")
    assert_equal "ruby", manifest.fetch("port")
    assert_equal LibTmux::Support::MINIMUM, manifest.dig("floor", "minimum")
    ids = (manifest.fetch("capabilities") + manifest.fetch("workarounds")).map { |entry| entry.fetch("id") }
    assert_equal ids.uniq, ids
    ids.each { |id| assert_match(/\A[a-z][a-z0-9]*(-[a-z0-9]+)*\z/, id) }
  end

  def test_every_refusal_names_the_error_and_every_flag_is_one_letter
    CAPABILITIES.each do |entry|
      assert_equal "LibTmux::UnsupportedFeatureError", entry.error if entry.handling == :refuse
      assert_includes %i[refuse fallback repair], entry.handling
    end
    (CAPABILITIES + WORKAROUNDS).flat_map(&:commands).each do |command|
      command.flags.each { |flag| assert_match(/\A-[A-Za-z]\z/, flag) }
    end
    WORKAROUNDS.each { |entry| assert_includes %i[refuse repair], entry.handling }
  end

  def test_every_api_name_is_a_public_symbol
    names = (CAPABILITIES + WORKAROUNDS).flat_map(&:apis) +
      CAPABILITIES.filter_map(&:error)
    names.each do |name|
      owner, separator, method = name.partition(/[#.]/)
      constant = Object.const_get(owner)
      case separator
      when "#" then assert constant.public_method_defined?(method), name
      when "." then assert constant.respond_to?(method), name
      else assert_kind_of Module, constant, name
      end
    end
  end

  def test_availability_follows_the_release_order
    gate = REGISTRY.capability("layout-mirrored-main")
    %w[3.3a 3.4 next-3.5 3.5-rc 3.5-rc2].each { |text| refute gate.available?(release(text)), text }
    %w[3.5 3.5a 3.7d 3.8-rc2 next-3.9].each { |text| assert gate.available?(release(text)), text }
  end

  def test_a_workaround_applies_to_its_exact_releases_only
    gate = REGISTRY.workaround("break-pane-misnames-windows")
    assert gate.applies?(release("3.7"))
    %w[3.6b 3.7a 3.7d 3.8 next-3.9].each { |text| refute gate.applies?(release(text)), text }
  end

  def test_an_unknown_id_is_an_error
    assert_raises(KeyError) { REGISTRY.capability("nope") }
    assert_raises(KeyError) { REGISTRY.workaround("nope") }
  end
end
