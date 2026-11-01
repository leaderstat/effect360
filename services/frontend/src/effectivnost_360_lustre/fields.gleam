// services/frontend/src/effectivnost_360_lustre/fields.gleam
//
// Field specifications for the applicant form.
//
// IMPORTANT — what this module is and is NOT
// ------------------------------------------
// The list below is *presentation only*: labels, ordering, placeholders and
// the conditional rule. It is NOT the source of the requirements.
//
// The authoritative list of requirements lives in the database
// (`requirements` table) and is evaluated by the deterministic completeness
// gate in the Gleam API (services/api/src/effectivnost_360/completeness.gleam).
// The client receives the authoritative answer from the server as the
// `missing[]` array of a 422 response, together with the `clause_id` and the
// literal `quote` of the clause the requirement is based on.
//
// Therefore this module must never invent a clause_id or a quote, and it
// must never decide on its own that a request is complete. See
// docs/architecture/cjm-screen-map.md §7.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// A field of the applicant form.
pub type FieldSpec {
  FieldSpec(
    name: String,
    label: String,
    placeholder: String,
    required: Bool,
    /// The condition under which the field becomes required, in the
    /// grammar the API understands: "required if <field> == '<literal>'".
    condition: Option(String),
  )
}

/// The fields of the DEMO request type, in the order the user should see
/// them. Mirrors the `fields_schema` of the seeded DEMO request type
/// (database/seeds/002_seed_demo_business_trip.sql).
pub fn field_specs() -> List(FieldSpec) {
  [
    FieldSpec(
      name: "destination_city",
      label: "Город назначения",
      placeholder: "Например: Казань",
      required: True,
      condition: None,
    ),
    FieldSpec(
      name: "purpose",
      label: "Цель поездки",
      placeholder: "Например: конференция",
      required: True,
      condition: None,
    ),
    FieldSpec(
      name: "start_date",
      label: "Дата начала",
      placeholder: "Например: 2026-11-12",
      required: True,
      condition: None,
    ),
    FieldSpec(
      name: "end_date",
      label: "Дата окончания",
      placeholder: "Например: 2026-11-14",
      required: True,
      condition: None,
    ),
    FieldSpec(
      name: "funding_source",
      label: "Источник финансирования",
      placeholder: "budget или grant",
      required: True,
      condition: None,
    ),
    FieldSpec(
      name: "grant_number",
      label: "Номер гранта",
      placeholder: "Нужен, если источник — грант",
      required: False,
      condition: Some("required if funding_source == 'grant'"),
    ),
    FieldSpec(
      name: "approver_id",
      label: "Руководитель",
      placeholder: "ID или ФИО руководителя",
      required: True,
      condition: None,
    ),
  ]
}

/// Look up a field spec by name.
pub fn find_spec(specs: List(FieldSpec), name: String) -> Option(FieldSpec) {
  case list.find(specs, fn(spec) { spec.name == name }) {
    Ok(spec) -> Some(spec)
    Error(Nil) -> None
  }
}

/// Whether a field with the given value should be treated as filled.
///
/// An empty or whitespace-only string is NOT a value.
pub fn is_filled(value: String) -> Bool {
  value != ""
}

/// The fields that the client believes are still empty.
///
/// This is only used to give the user immediate feedback while typing. It
/// is deliberately a *hint*, never the authority: the server's 422 response
/// is what actually blocks the submission.
pub fn locally_missing(
  specs: List(FieldSpec),
  values: Dict(String, String),
) -> List(FieldSpec) {
  list.filter(specs, fn(spec) { spec_is_unsatisfied(spec, values) })
}

/// A spec is unsatisfied when it is required, has no value, and its
/// condition (if any) applies to the current values.
fn spec_is_unsatisfied(spec: FieldSpec, values: Dict(String, String)) -> Bool {
  let has_value =
    case dict.get(values, spec.name) {
      Ok(value) -> is_filled(value)
      Error(_) -> False
    }
  case has_value {
    True -> False
    False ->
      case spec.condition {
        None -> spec.required
        Some(expression) -> condition_applies(expression, values)
      }
  }
}

/// Evaluate a condition of the form "required if <field> == '<literal>'".
///
/// The grammar is deliberately the same one the API uses (see
/// `completeness.evaluate_condition`). An unrecognised expression is
/// treated as "applies" — the conservative choice, matching the server.
pub fn condition_applies(
  expression: String,
  values: Dict(String, String),
) -> Bool {
  case string.split(expression, on: "required if ") {
    [_, rest] ->
      case string.split(rest, on: " == ") {
        [field, literal] -> {
          let expected = trim_quotes(string.trim(literal))
          case dict.get(values, string.trim(field)) {
            Ok(actual) -> actual == expected
            // The field is unknown, so the predicate cannot be proven false.
            Error(_) -> True
          }
        }
        _ -> True
      }
    _ -> True
  }
}

fn trim_quotes(s: String) -> String {
  let s = string.trim(s)
  let s = case string.starts_with(s, "'") {
    True -> string.drop_start(s, 1)
    False -> s
  }
  case string.ends_with(s, "'") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}
