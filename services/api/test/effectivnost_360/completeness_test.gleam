// services/api/test/effectivnost_360/completeness_test.gleam
//
// Unit tests for completeness.gleam. Pure-function tests, no DB / HTTP.
//
// Run with: cd services/api && gleam test
import effectivnost_360/completeness as comp
import gleam/dict
import gleam/list
import gleam/option
import gleeunit/should

type Requirement =
  comp.Requirement

type Outcome =
  comp.Outcome

type Missing =
  comp.Missing

type Fields =
  comp.Fields

fn req(
  field: String,
  required: Bool,
  cond: option.Option(String),
) -> Requirement {
  comp.Requirement(
    id: 1,
    field_name: field,
    required: required,
    condition: cond,
    clause_id: "p.test",
    clause_ref: option.None,
    quote: "quote for " <> field,
  )
}

fn req_with_clause(
  field: String,
  required: Bool,
  cond: option.Option(String),
  clause_id: String,
  quote: String,
) -> Requirement {
  comp.Requirement(
    id: 1,
    field_name: field,
    required: required,
    condition: cond,
    clause_id: clause_id,
    clause_ref: option.None,
    quote: quote,
  )
}

fn f(pairs: List(#(String, String))) -> Fields {
  pairs
  |> comp.fields_from_pairs
}

fn find_missing(outcome: Outcome, field: String) -> Result(Missing, Nil) {
  list.find(outcome.missing, fn(m) { m.field_name == field })
}

pub fn all_required_filled_test() {
  let reqs = [
    req("destination_city", True, option.None),
    req("purpose", True, option.None),
    req("start_date", True, option.None),
  ]
  let fields =
    f([
      #("destination_city", "Казань"),
      #("purpose", "конференция"),
      #("start_date", "2026-11-12"),
    ])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
  should.equal(outcome.missing, [])
  should.be_true(list.contains(outcome.satisfied, "destination_city"))
}

pub fn missing_required_field_test() {
  let reqs = [req("destination_city", True, option.None)]
  let fields = f([])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  should.equal(list.length(outcome.missing), 1)
  let assert Ok(_) = find_missing(outcome, "destination_city")
  Nil
}

pub fn empty_string_is_missing_test() {
  let reqs = [req("destination_city", True, option.None)]
  let fields = f([#("destination_city", "")])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  let assert Ok(_) = find_missing(outcome, "destination_city")
  Nil
}

pub fn not_required_field_absent_test() {
  let reqs = [req("grant_number", False, option.None)]
  let fields = f([])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
}

pub fn conditional_met_missing_test() {
  let reqs = [
    req("funding_source", True, option.None),
    req(
      "grant_number",
      False,
      option.Some("required if funding_source == 'grant'"),
    ),
  ]
  let fields = f([#("funding_source", "grant")])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  let assert Ok(_m) = find_missing(outcome, "grant_number")
  Nil
}

pub fn conditional_not_applicable_missing_is_ok_test() {
  let reqs = [
    req("funding_source", True, option.None),
    req(
      "grant_number",
      False,
      option.Some("required if funding_source == 'grant'"),
    ),
  ]
  let fields = f([#("funding_source", "budget")])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
}

pub fn conditional_present_when_required_test() {
  let reqs = [
    req("funding_source", True, option.None),
    req(
      "grant_number",
      False,
      option.Some("required if funding_source == 'grant'"),
    ),
  ]
  let fields =
    f([#("funding_source", "grant"), #("grant_number", "RSF-24-1-2")])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
}

pub fn unknown_condition_is_conservative_test() {
  let reqs = [
    req(
      "weird_field",
      False,
      option.Some("required if foo in [bar, baz]"),
    ),
  ]
  let fields = f([#("foo", "bar")])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  let assert Ok(_) = find_missing(outcome, "weird_field")
  Nil
}

pub fn fields_from_pairs_round_trip_test() {
  let fields =
    f([
      #("city", "Казань"),
      #("count", "3"),
      #("flag", "true"),
      #("nested", ""),
    ])
  should.equal(dict.get(fields, "city"), Ok("Казань"))
  should.equal(dict.get(fields, "count"), Ok("3"))
  should.equal(dict.get(fields, "flag"), Ok("true"))
  should.equal(dict.get(fields, "nested"), Ok(""))
  should.equal(dict.get(fields, "absent"), Error(Nil))
}

pub fn evaluate_condition_handles_quotes_test() {
  let fields = f([#("funding_source", "grant")])
  should.be_true(
    comp.evaluate_condition(
      option.Some("required if funding_source == 'grant'"),
      fields,
    ),
  )
  let fields2 = f([#("funding_source", "budget")])
  should.be_false(
    comp.evaluate_condition(
      option.Some("required if funding_source == 'grant'"),
      fields2,
    ),
  )
}

pub fn evaluate_condition_no_condition_test() {
  let fields = f([])
  should.be_true(comp.evaluate_condition(option.None, fields))
}

pub fn missing_carries_clause_and_quote_test() {
  let reqs = [
    req_with_clause(
      "destination_city",
      True,
      option.None,
      "p.3",
      "город и место назначения, цель поездки",
    ),
  ]
  let outcome = comp.check(reqs, f([]))
  should.be_false(outcome.complete)
  let assert Ok(m) = find_missing(outcome, "destination_city")
  should.equal(m.clause_id, "p.3")
  should.equal(m.quote, "город и место назначения, цель поездки")
  should.equal(m.required, True)
  should.be_true(m.conditional == False)
}

pub fn non_required_with_no_condition_and_empty_value_is_ok_test() {
  let reqs = [req("note", False, option.None)]
  let fields = f([#("note", "")])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
}

// --- The "!=" operator and the jsonb object wrapper --------------------
//
// The `condition` column is jsonb, so the same expression may arrive as a
// bare string or wrapped in {"expression": "…"}. Both must be understood,
// otherwise a conditional requirement fires when it should not.

pub fn not_equal_condition_applies_test() {
  let reqs = [
    req(
      "written_consent_disability",
      False,
      option.Some("required if disability_group != 'none'"),
    ),
  ]
  // disability_group is 'disabled' -> the condition applies -> the field
  // is required and therefore missing.
  let fields = f([#("disability_group", "disabled")])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  should.equal(list.length(outcome.missing), 1)
}

pub fn not_equal_condition_does_not_apply_test() {
  let reqs = [
    req(
      "written_consent_disability",
      False,
      option.Some("required if disability_group != 'none'"),
    ),
  ]
  // disability_group is 'none' -> the condition does not apply -> the
  // requirement is satisfied trivially.
  let fields = f([#("disability_group", "none")])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
  should.equal(outcome.missing, [])
}

pub fn jsonb_object_condition_is_understood_test() {
  let reqs = [
    req(
      "grant_number",
      False,
      option.Some("{\"expression\": \"required if funding_source == 'grant'\"}"),
    ),
  ]
  // funding_source is 'budget' -> the condition does not apply.
  let fields = f([#("funding_source", "budget")])
  let outcome = comp.check(reqs, fields)
  should.be_true(outcome.complete)
  should.equal(outcome.missing, [])
}

pub fn jsonb_object_condition_applies_test() {
  let reqs = [
    req(
      "grant_number",
      False,
      option.Some("{\"expression\": \"required if funding_source == 'grant'\"}"),
    ),
  ]
  // funding_source is 'grant' -> the condition applies -> missing.
  let fields = f([#("funding_source", "grant")])
  let outcome = comp.check(reqs, fields)
  should.be_false(outcome.complete)
  should.equal(list.length(outcome.missing), 1)
}
