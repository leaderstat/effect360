// services/api/test/effectivnost_360/hard_stop_test.gleam
//
// Unit tests for the blocking rules (`requirement_hard_stops`).
//
// A hard stop is NOT a missing field: the applicant filled the field in
// and the value itself is prohibited by a regulation. The two lists must
// stay apart so the UI can say "заполните поле" and "отправка запрещена"
// in different words.
//
// Pure-function tests, no DB / HTTP. Run with:
//   cd services/api && gleam test
import effectivnost_360/completeness as comp
import gleam/list
import gleam/option
import gleeunit/should

type Fields =
  comp.Fields

type HardStopHit =
  comp.HardStopHit

fn f(pairs: List(#(String, String))) -> Fields {
  pairs
  |> comp.fields_from_pairs
}

fn block_rule(field: String, trigger: String) -> comp.HardStopRule {
  comp.HardStopRule(
    field_name: field,
    trigger_expr: trigger,
    action: comp.BlockSubmit,
    reason: "запрещено нормой",
    clause_id: "clause.test",
    clause_ref: option.Some("Ст. 259 ч. 1 ТК РФ"),
    quote: "цитата нормы",
    regulatory_ref_id: option.Some("ref-1"),
  )
}

fn review_rule(field: String, trigger: String) -> comp.HardStopRule {
  comp.HardStopRule(
    field_name: field,
    trigger_expr: trigger,
    action: comp.NeedsEmployerReview,
    reason: "требуется подтверждение работодателем",
    clause_id: "clause.test",
    clause_ref: option.Some("Ст. 203 ч. 3 ТК РФ"),
    quote: "цитата нормы",
    regulatory_ref_id: option.Some("ref-2"),
  )
}

// --- The rules are not triggered when the value is harmless -------------

pub fn no_trigger_when_field_absent_test() {
  let rules = [block_rule("is_pregnant", "is_pregnant == 'true'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("destination_city", "Казань")]), rules)
  should.equal(outcome.hard_stops, [])
  should.be_true(outcome.complete)
}

// --- block_submit: the submission is forbidden -------------------------

pub fn block_submit_triggers_test() {
  let rules = [block_rule("is_pregnant", "is_pregnant == 'true'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("is_pregnant", "true")]), rules)
  should.equal(list.length(outcome.hard_stops), 1)
  should.be_false(outcome.complete)
}

pub fn block_submit_carries_reason_and_ref_test() {
  let rules = [block_rule("is_pregnant", "is_pregnant == 'true'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("is_pregnant", "true")]), rules)
  let hit = list.first(outcome.hard_stops)
  case hit {
    Error(_) -> panic as "hard stop expected"
    Ok(h) -> check_hit(h)
  }
}

fn check_hit(h: HardStopHit) {
  {
    should.equal(h.field_name, "is_pregnant")
    should.equal(h.clause_id, "clause.test")
    should.equal(h.quote, "цитата нормы")
    should.equal(h.reason, "запрещено нормой")
    should.equal(h.regulatory_ref_id, option.Some("ref-1"))
  }
}

// --- needs_employer_review does NOT block the completeness -------------

pub fn needs_employer_review_does_not_block_test() {
  let rules = [review_rule("has_apprentice_contract", "has_apprentice_contract == 'true'")]
  let outcome =
    comp.check_with_hard_stops(
      [],
      f([#("has_apprentice_contract", "true")]),
      rules,
    )
  should.equal(list.length(outcome.hard_stops), 1)
  // The employer has to confirm, but the applicant may still submit.
  should.be_true(outcome.complete)
}

// --- A hard stop and a missing field are different things ---------------

pub fn hard_stop_and_missing_are_separate_test() {
  let reqs = [comp.Requirement(
    id: 1,
    field_name: "purpose",
    required: True,
    condition: option.None,
    clause_id: "clause.test",
    clause_ref: option.None,
    quote: "quote",
  )]
  let rules = [block_rule("is_pregnant", "is_pregnant == 'true'")]
  let outcome =
    comp.check_with_hard_stops(
      reqs,
      f([#("is_pregnant", "true")]),
      rules,
    )
  // The purpose field is missing, and the pregnancy rule blocks it.
  should.equal(list.length(outcome.missing), 1)
  should.equal(list.length(outcome.hard_stops), 1)
  should.be_false(outcome.complete)
}

// --- Trigger grammar ---------------------------------------------------

pub fn inequality_trigger_test() {
  let rules = [block_rule("employment_type", "employment_type != 'employee'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("employment_type", "gph")]), rules)
  should.equal(list.length(outcome.hard_stops), 1)
}

pub fn inequality_trigger_not_fired_on_match_test() {
  let rules = [block_rule("employment_type", "employment_type != 'employee'")]
  let outcome =
    comp.check_with_hard_stops(
      [],
      f([#("employment_type", "employee")]),
      rules,
    )
  should.equal(outcome.hard_stops, [])
  should.be_true(outcome.complete)
}

pub fn in_operator_test() {
  let rules = [block_rule("trip_scope", "trip_scope in 'international,abroad'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("trip_scope", "international")]), rules)
  should.equal(list.length(outcome.hard_stops), 1)
}

pub fn in_operator_not_fired_test() {
  let rules = [block_rule("trip_scope", "trip_scope in 'international,abroad'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("trip_scope", "domestic")]), rules)
  should.equal(outcome.hard_stops, [])
}

pub fn whitespace_tolerant_trigger_test() {
  let rules = [block_rule("is_under_18", "is_under_18  ==  'true'")]
  let outcome =
    comp.check_with_hard_stops([], f([#("is_under_18", "true")]), rules)
  should.equal(list.length(outcome.hard_stops), 1)
}

// --- An unparsable trigger never blocks --------------------------------

pub fn unparsable_trigger_is_ignored_test() {
  let rules = [block_rule("is_pregnant", "totally broken expression")]
  let outcome =
    comp.check_with_hard_stops([], f([#("is_pregnant", "true")]), rules)
  should.equal(outcome.hard_stops, [])
  should.be_true(outcome.complete)
}

// --- Several rules can trigger at once ----------------------------------

pub fn several_rules_trigger_test() {
  let rules = [
    block_rule("is_pregnant", "is_pregnant == 'true'"),
    block_rule("is_under_18", "is_under_18 == 'true'"),
    block_rule("employment_type", "employment_type == 'gph'"),
  ]
  let outcome =
    comp.check_with_hard_stops(
      [],
      f([
        #("is_pregnant", "true"),
        #("is_under_18", "true"),
        #("employment_type", "gph"),
      ]),
      rules,
    )
  should.equal(list.length(outcome.hard_stops), 3)
  should.be_false(outcome.complete)
}
