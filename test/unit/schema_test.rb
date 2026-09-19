# frozen_string_literal: true

require "minitest/autorun"
require "json_schemer"
require_relative "../../gems/libtmux/lib/libtmux/criteria"

class CriteriaSchemaTest < Minitest::Test
  def test_generated_schema_and_decoder_accept_the_same_wire_grammar
    schema = LibTmux::FilterExpr.json_schema
    assert schema.frozen?
    assert schema.fetch("$defs").frozen?
    assert JSONSchemer.valid_schema?(schema)
    validator = JSONSchemer.schema(schema)
    accepted = {
      pane: [{}, {active: false}, {currentCommand: {startsWith: "nv"}},
        {deadStatus: nil}, {index: {not: {in: [2, 12]}}}, {or: []}],
      window: [{panes: {some: {active: true, currentCommand: "cat"}}},
        {activePane: {isNot: nil}}],
      session: [{currentWindow: {is: {panes: {every: {dead: false}}}}}],
      window_link: [{index: {gte: 0}}],
      client: [{height: nil}, {session: {is: nil}}]
    }
    accepted.each do |entity, cases|
      cases.each do |where|
        envelope = {profile: LibTmux::FilterExpr::PROFILE, version: 1, entity: entity.to_s, where: where}
        input = JSON.parse(JSON.generate(envelope))
        assert validator.valid?(input), "schema rejected #{entity} criterion"
        expression = LibTmux::FilterExpr.from_json(JSON.generate(input))
        assert validator.valid?(expression.to_h), "schema rejected normalized #{entity} criterion"
      end
    end
    rejected = [{active: "0"}, {active: nil}, {index: -1}, {index: 4_294_967_296},
      {index: {contains: "1"}}, {current_command: "cat"},
      {currentCommand: {starts_with: "ca"}}, {currentCommand: {regex: "cat"}},
      {window: {is: nil}}, {unknownField: true}, {or: [{}, {title: 7}]}]
    rejected.each do |where|
      envelope = {profile: LibTmux::FilterExpr::PROFILE, version: 1, entity: "pane", where: where}
      wire = JSON.generate(envelope)
      refute validator.valid?(JSON.parse(wire)), "schema accepted invalid criterion"
      assert_raises(LibTmux::InvalidFilterError) { LibTmux::FilterExpr.from_json(wire) }
    end
    # JSON Schema integers are mathematical; the Ruby decoder also rejects float tokens.
    float_token = '{"profile":"libtmux-ruby.where","version":1,"entity":"pane","where":{"index":1.0}}'
    assert validator.valid?(JSON.parse(float_token))
    assert_raises(LibTmux::InvalidFilterError) { LibTmux::FilterExpr.from_json(float_token) }
  end
end
