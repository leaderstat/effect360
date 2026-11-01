// services/api/src/effectivnost_360/completeness.gleam
//
// Deterministic completeness check for a draft request.
//
// Contract:
//   - Pure function: no I/O, no LLM, no NATS, no time-of-day.
//   - Operates on a list of Requirement (from the regulations table) and
//     the request's `fields` jsonb (already extracted by the Go consumer).
//   - Returns a structured outcome: list of missing fields, each carrying
//     the field_name, the clause_id, the literal quote from the regulation,
//     and whether the requirement was conditional (and which condition).
//   - A requirement is considered satisfied when:
//       * its `required` flag is false, OR
//       * its `fields[requirement.field_name]` is non-null (present and not empty), OR
//       * the `condition` is present but evaluates to false (e.g.
//         "required if funding_source == 'grant'" — if funding_source is
//         "budget", the requirement is satisfied trivially).
//   - Condition expressions supported today (string-only):
//       "required if <field_name> == '<literal>'"
//     e.g. "required if funding_source == 'grant'"
//     The check is exact-string comparison of the literal value to the
//     field value in `fields`. Unknown conditions are conservative:
//     the requirement is treated as required (so the caller must confirm
//     the predicate before releasing the request).
//
// Safety:
//   - This module never touches raw text. The PII boundary is enforced
//     upstream in the consumer.
//   - This module never decides on `enabled=true/false` for a request
//     type. That is an admin decision, not a completeness one.
//   - This module never issues HTTP calls or SQL queries. It is pure.
//
// The companion tests in test/effectivnost_360/completeness_test.gleam
// cover: all required filled, missing required, conditional satisfied,
// conditional unmet, non-required ignored, missing field is null vs empty,
// unknown condition is conservative, and edge cases.
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/string

/// A requirement loaded from the database (only the columns completeness
/// needs; everything else is the responsibility of the regulation UI).
pub type Requirement {
  Requirement(
    id: Int,
    field_name: String,
    required: Bool,
    condition: Option(String),
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// `None` when the clause has no readable reference yet.
    clause_ref: Option(String),
    quote: String,
  )
}

/// A blocking rule loaded from `requirement_hard_stops`. Different from a
/// `Requirement`: the field is *present*, but its value violates a
/// regulation, so the request MUST NOT be submitted (or must be confirmed
/// by an employer). The completeness check returns these separately so
/// the UI can render them as a banner rather than a normal `missing` row.
pub type HardStopRule {
  HardStopRule(
    field_name: String,
    /// Predicate grammar (see `evaluate_trigger` below):
    ///   "<field> == '<literal>'"
    ///   "<field> != '<literal>'"
    ///   "<field> in 'a,b,c'"
    trigger_expr: String,
    action: HardStopAction,
    reason: String,
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// `None` for rules created before migration 010; the API then falls
    /// back to the raw clause id.
    clause_ref: Option(String),
    quote: String,
    /// External regulatory reference id (UUID), if the rule was loaded
    /// from `requirement_hard_stops.regulatory_ref_id`. Optional because
    /// unit tests pass synthetic rules.
    regulatory_ref_id: Option(String),
  )
}

/// Outcome of a blocking rule. Mirrors the CHECK constraint on
/// `requirement_hard_stops.action` in the database.
pub type HardStopAction {
  BlockSubmit
  NeedsEmployerReview
}

/// One triggered blocking rule.
pub type HardStopHit {
  HardStopHit(
    field_name: String,
    action: HardStopAction,
    reason: String,
    clause_id: String,
    clause_ref: Option(String),
    quote: String,
    regulatory_ref_id: Option(String),
  )
}

/// One missing requirement in the response from `check`.
pub type Missing {
  Missing(
    field_name: String,
    required: Bool,
    conditional: Bool,
    reason: String,
    clause_id: String,
    /// Human-readable normative reference, e.g. "Ст. 259 ч. 1 ТК РФ".
    /// `None` when the clause has no readable reference yet.
    clause_ref: Option(String),
    quote: String,
  )
}

/// Outcome of `check`.
pub type Outcome {
  Outcome(
    missing: List(Missing),
    satisfied: List(String),
    hard_stops: List(HardStopHit),
    /// True only when no `Missing` AND no triggered `HardStopHit` of
    /// action `BlockSubmit`. `NeedsEmployerReview` does NOT block
    /// completeness — it is surfaced separately so the employer can
    /// confirm in the workflow.
    complete: Bool,
  )
}

/// The shape of `fields` as seen by completeness. Tolerant: missing
/// keys are not an error at the type level (we look them up dynamically).
pub type Fields =
  dict.Dict(String, String)

/// Build a Fields from a Gleam string-to-string map directly.
/// This is the canonical entry point used by the API: the request
/// endpoint already decodes the jsonb into a typed dict before
/// calling completeness. Non-string values must be coerced upstream.
pub fn fields_from_pairs(pairs: List(#(String, String))) -> Fields {
  pairs
  |> dict.from_list
}

/// The expected predicate grammar, conservative: anything we don't
/// recognise is treated as "applies" so the requirement stays
/// required and the request must NOT be submitted until the admin
/// confirms the condition semantics.
///
/// This is the safe default: if the grammar is ambiguous we err on
/// the side of requiring the field rather than silently letting an
/// unverified condition through.
pub fn evaluate_condition(condition: Option(String), fields: Fields) -> Bool {
  case condition {
    option.None -> True
    option.Some(raw) -> {
      let expr = normalise_condition(raw)
      // Grammar: "required if <field> <op> '<literal>'"
      // We only evaluate this exact shape; anything else is conservative
      // and returns True (= condition applies, requirement is required).
      let parts = string.split(expr, on: "required if ")
      case parts {
        [_, rest] -> evaluate_predicate(rest, fields)
        _ -> evaluate_predicate(expr, fields)
      }
    }
  }
}

/// Normalise the raw `condition` value into a bare expression.
///
/// The column is jsonb, so `condition::text` yields one of:
///
///   "required if funding_source == 'grant'"    a jsonb string (with the
///                                              surrounding double quotes)
///   {"expression": "required if …"}            a jsonb object
///   required if funding_source == 'grant'      already a bare string
///
/// All three must end up as the same bare expression, otherwise the
/// parser reads the leading quote as part of the field name and every
/// conditional requirement fires unconditionally.
fn normalise_condition(raw: String) -> String {
  let trimmed = string.trim(raw)
  case string.starts_with(trimmed, "{") {
    True -> strip_expression_object(trimmed)
    False -> strip_json_quotes(trimmed)
  }
}

/// Strip the jsonb object wrapper: {"expression": "…"} -> "…".
fn strip_expression_object(trimmed: String) -> String {
  case string.split(trimmed, on: "\"expression\"") {
    [_, rest] ->
      case string.split(rest, on: ":") {
        [_, rest2] -> {
          let after_colon = string.trim(rest2)
          // Drop the closing brace of the object.
          let without_brace = case string.ends_with(after_colon, "}") {
            True -> string.drop_end(after_colon, 1)
            False -> after_colon
          }
          strip_json_quotes(string.trim(without_brace))
        }
        _ -> trimmed
      }
    _ -> trimmed
  }
}

/// Strip a pair of surrounding double quotes, if present.
fn strip_json_quotes(value: String) -> String {
  let trimmed = string.trim(value)
  case string.starts_with(trimmed, "\"") {
    False -> trimmed
    True -> {
      let without_start = string.drop_start(trimmed, 1)
      case string.ends_with(without_start, "\"") {
        True -> string.drop_end(without_start, 1)
        False -> without_start
      }
    }
  }
}

/// Evaluate "<field> == '<literal>'" or "<field> != '<literal>'".
fn evaluate_predicate(predicate: String, fields: Fields) -> Bool {
  // "!=" is checked first: it is a different operator from "==".
  let ne_parts = string.split(predicate, on: " != ")
  case ne_parts {
    [field, literal] -> {
      let expected = unquote_literal(string.trim(literal))
      case dict.get(fields, string.trim(field)) {
        Ok(actual) -> actual != expected
        // If the field is missing, we cannot prove the predicate;
        // conservative default is to require the field.
        Error(_) -> True
      }
    }
    _ ->
      case string.split(predicate, on: " == ") {
        [field, literal] -> {
          let expected = unquote_literal(string.trim(literal))
          case dict.get(fields, string.trim(field)) {
            Ok(actual) -> actual == expected
            // If the field is missing, we cannot prove the predicate;
            // conservative default is to require the field.
            Error(_) -> True
          }
        }
        // Unrecognised shape: conservative, applies.
        _ -> True
      }
  }
}

/// Main entry point. Pure function.
pub fn check(
  requirements: List(Requirement),
  fields: Fields,
) -> Outcome {
  check_with_hard_stops(requirements, fields, [])
}

/// Same as `check`, but also evaluates the blocking rules.
///
/// A hard stop is NOT a "missing field": the applicant filled the field in
/// and the value itself is prohibited by a regulation (e.g. `is_pregnant
/// == 'true'`). The two lists are kept apart so the UI can say
/// "заполните поле" and "отправка запрещена" in different words.
pub fn check_with_hard_stops(
  requirements: List(Requirement),
  fields: Fields,
  hard_stop_rules: List(HardStopRule),
) -> Outcome {
  let outcomes =
    requirements
    |> list.map(fn(req) { evaluate_one(req, fields) })

  let missing =
    outcomes
    |> list.filter_map(fn(o) {
      case o {
        Ok(_) -> Error(Nil)
        Error(m) -> Ok(m)
      }
    })

  let satisfied =
    outcomes
    |> list.filter_map(fn(o) {
      case o {
        Ok(name) -> Ok(name)
        Error(_) -> Error(Nil)
      }
    })

  let hard_stops =
    hard_stop_rules
    |> list.filter_map(fn(rule) { evaluate_hard_stop(rule, fields) })

  let blocked =
    hard_stops
    |> list.any(fn(h) {
      case h.action {
        BlockSubmit -> True
        NeedsEmployerReview -> False
      }
    })

  Outcome(
    missing: missing,
    satisfied: satisfied,
    hard_stops: hard_stops,
    complete: list.is_empty(missing) && !blocked,
  )
}

/// Evaluate one blocking rule against the request fields.
///
/// Returns `Error(Nil)` when the rule does not trigger.
///
/// The trigger grammar is deliberately tiny and fully deterministic:
///   "<field> == '<literal>'"   exact string equality
///   "<field> != '<literal>'"   string inequality
///   "<field> in 'a,b,c'"      membership in a comma-separated list
///
/// Anything we cannot parse is treated as NOT triggered — we never block
/// a submission because of a rule we failed to understand. The database
/// CHECK constraint guarantees the shape of the expression, so an
/// unparsable expression means corrupted data, not a new grammar.
pub fn evaluate_hard_stop(
  rule: HardStopRule,
  fields: Fields,
) -> Result(HardStopHit, Nil) {
  case parse_trigger(rule.trigger_expr) {
    Error(_) -> Error(Nil)
    Ok(#(op, field_name, literal)) -> {
      let actual = dict.get(fields, field_name)
      let triggered = case actual {
        Error(_) -> False
        Ok(value) -> {
          case op {
            "==" -> value == literal
            "!=" -> value != literal
            "in" -> {
              let options = string.split(literal, on: ",")
              list.any(options, fn(v) { string.trim(v) == value })
            }
            _ -> False
          }
        }
      }
      case triggered {
        False -> Error(Nil)
        True ->
          Ok(HardStopHit(
            field_name: rule.field_name,
            action: rule.action,
            reason: rule.reason,
            clause_id: rule.clause_id,
            clause_ref: rule.clause_ref,
            quote: rule.quote,
            regulatory_ref_id: rule.regulatory_ref_id,
          ))
      }
    }
  }
}

/// Parse a trigger expression into #(operator, field_name, literal).
///
/// Supported shapes (whitespace tolerant):
///   "field == 'value'"
///   "field != 'value'"
///   "field in 'a,b,c'"
fn parse_trigger(expr: String) -> Result(#(String, String, String), Nil) {
  let trimmed = string.trim(expr)
  // The `in` operator is two words, the others are symbol operators.
  case string.split(trimmed, on: " in ") {
    [left, right] -> {
      let field = string.trim(left)
      let literal = unquote_literal(string.trim(right))
      case field == "" {
        True -> Error(Nil)
        False -> Ok(#("in", field, literal))
      }
    }
    _ -> {
      case string.split(trimmed, on: "==") {
        [left, right] ->
          Ok(#("==", string.trim(left), unquote_literal(string.trim(right))))
        _ ->
          case string.split(trimmed, on: "!=") {
            [left, right] ->
              Ok(#("!=", string.trim(left), unquote_literal(string.trim(right))))
            _ -> Error(Nil)
          }
      }
    }
  }
}

/// Strip the surrounding single quotes of a literal, if present.
fn unquote_literal(literal: String) -> String {
  let stripped = case string.starts_with(literal, "'") {
    True -> string.drop_start(literal, 1)
    False -> literal
  }
  case string.ends_with(stripped, "'") {
    True -> string.drop_end(stripped, 1)
    False -> stripped
  }
}

fn evaluate_one(req: Requirement, fields: Fields) -> Result(String, Missing) {
  let field_value = dict.get(fields, req.field_name)
  let present = case field_value {
    Ok("") -> False
    Ok(_) -> True
    Error(_) -> False
  }

  let has_condition = case req.condition {
    option.Some(_) -> True
    option.None -> False
  }

  // If the field is present, we are satisfied.
  case present {
    True -> Ok(req.field_name)
    False -> {
      // Field is missing. Is the requirement trivially satisfied because
      // it's not required, or because the condition does not apply?
      case req.required, has_condition {
        // Not required at all (and no condition) -> satisfied trivially.
        False, False -> Ok(req.field_name)
        // Required, no condition -> missing.
        True, False -> Error(missing_for(req, "required_field_absent", False))
        // Required, has condition: condition must apply.
        True, True -> {
          let applies = evaluate_condition(req.condition, fields)
          case applies {
            False -> Ok(req.field_name)
            True -> Error(missing_for(req, "conditional_unmet", True))
          }
        }
        // Not required, but has a condition -> the condition overrides the
        // required flag; if it applies the requirement becomes required.
        False, True -> {
          let applies = evaluate_condition(req.condition, fields)
          case applies {
            False -> Ok(req.field_name)
            True -> Error(missing_for(req, "conditional_unmet", True))
          }
        }
      }
    }
  }
}

fn missing_for(req: Requirement, reason: String, conditional: Bool) -> Missing {
  Missing(
    field_name: req.field_name,
    required: req.required,
    conditional: conditional,
    reason: reason,
    clause_id: req.clause_id,
    clause_ref: req.clause_ref,
    quote: req.quote,
  )
}

// --------------------------------------------------------------------
// JSON encoders for the Outcome / Missing so the API can return a
// structured body. Built with the typed `json.object` constructor
// (the three-argument list form) so we don't depend on json.array
// behaviour that varies across gleam_json versions.

pub fn outcome_to_json(o: Outcome) -> json.Json {
  json.object([
    #("complete", json.bool(o.complete)),
    #(
      "satisfied",
      json.array(from: o.satisfied, of: json.string),
    ),
    #(
      "missing",
      json.array(from: o.missing, of: missing_to_json),
    ),
    #(
      "hard_stops",
      json.array(from: o.hard_stops, of: hard_stop_to_json),
    ),
  ])
}

/// Render one missing requirement for the API answer.
pub fn missing_to_json(m: Missing) -> json.Json {
  json.object([
    #("field_name", json.string(m.field_name)),
    #("required", json.bool(m.required)),
    #("conditional", json.bool(m.conditional)),
    #("reason", json.string(m.reason)),
    #("clause_id", json.string(m.clause_id)),
    #(
      "clause_ref",
      case m.clause_ref {
        option.Some(ref) -> json.string(ref)
        option.None -> json.null()
      },
    ),
    #("quote", json.string(m.quote)),
  ])
}

/// Render a triggered blocking rule for the API answer.
pub fn hard_stop_to_json(h: HardStopHit) -> json.Json {
  json.object([
    #("field_name", json.string(h.field_name)),
    #("action", json.string(hard_stop_action_to_string(h.action))),
    #("reason", json.string(h.reason)),
    #("clause_id", json.string(h.clause_id)),
    #(
      "clause_ref",
      case h.clause_ref {
        option.Some(ref) -> json.string(ref)
        option.None -> json.null()
      },
    ),
    #("quote", json.string(h.quote)),
    #(
      "regulatory_ref_id",
      case h.regulatory_ref_id {
        option.Some(id) -> json.string(id)
        option.None -> json.null()
      },
    ),
  ])
}

/// The wire representation of a blocking action.
pub fn hard_stop_action_to_string(action: HardStopAction) -> String {
  case action {
    BlockSubmit -> "block_submit"
    NeedsEmployerReview -> "needs_employer_review"
  }
}
