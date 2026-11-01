//// services/frontend/test/effectivnost_360_lustre_test.gleam
////
//// Unit tests for the Lustre frontend logic.
////
//// The browser-level behaviour is covered by the Playwright E2E suite
//// (scripts/qa_e2e.mjs). These tests cover the pure parts:
////  * the init model,
////  * the HTTP-status → outcome classification (the browser must never
////    show a fake success),
////  * the CJM route parsing,
////  * the local field-completeness hint.

import gleeunit
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}

import effectivnost_360_lustre/api_client.{
  type RequestStatus, type SubmitOutcome,
  Completed, Draft, InProgress, OtherStatus, Returned, Submitted,
  SubmitConflict, SubmitIncomplete, SubmitInvalid,
  SubmitNotFound, SubmitServerError, SubmitSucceeded, classify_submit,
  missing_field_decoder, parse_status, status_to_string,
}
import effectivnost_360_lustre/app.{
  TextChanged, init, update,
}
import effectivnost_360_lustre/fields.{
  field_specs, find_spec, is_filled, locally_missing,
}
import effectivnost_360_lustre/screen.{
  is_request_screen, parse_route, path_for, path_for_new_request,
  screen_title, step_number,
} as screen_map

pub fn main() {
  gleeunit.main()
}

// --- init / model --------------------------------------------------------

pub fn init_provides_idempotency_key_test() {
  let #(m, _) = init(Nil)
  assert m.idempotency_key != ""
  assert m.text == ""
  assert m.busy == False
  case m.request {
    None -> Nil
    Some(_) -> panic as "expected None"
  }
  assert m.values == dict.new()
  assert m.server_missing == []
  assert m.outcome == None
  assert m.error_text == None
}

pub fn init_starts_on_start_screen_test() {
  let #(m, _) = init(Nil)
  assert m.screen == screen_map.Start
  assert m.route.request_id == None
}

pub fn text_changed_updates_model_test() {
  let #(m, _) = init(Nil)
  let #(next, _) = update(m, TextChanged("поездка в Казань"))
  assert next.text == "поездка в Казань"
}

// --- classify_submit: the HTTP status → outcome contract ------------------

pub fn classify_submit_200_is_succeeded_test() {
  let body = "{\"status\":\"submitted\",\"submitted_at\":\"2026-10-23T10:00:00Z\"}"
  let outcome: SubmitOutcome = classify_submit(200, body)
  case outcome {
    SubmitSucceeded(timestamp) -> {
      assert timestamp == "2026-10-23T10:00:00Z"
    }
    _ -> panic as "expected SubmitSucceeded"
  }
}

pub fn classify_submit_200_without_timestamp_is_still_success_test() {
  case classify_submit(200, "{}") {
    SubmitSucceeded("") -> Nil
    _ -> panic as "expected SubmitSucceeded with empty timestamp"
  }
}

pub fn classify_submit_422_is_incomplete_test() {
  let body =
    "{\"complete\":false,\"missing\":[{\"field_name\":\"destination_city\","
    <> "\"required\":true,\"conditional\":false,\"reason\":\"r\","
    <> "\"clause_id\":\"demo-1.1\",\"quote\":\"q\"}]}"
  case classify_submit(422, body) {
    SubmitIncomplete(items) -> {
      assert list.length(items) == 1
      let assert Ok(first) = list.first(items)
      assert first.field_name == "destination_city"
      assert first.clause_id == "demo-1.1"
      assert first.quote == "q"
      assert first.required == True
    }
    _ -> panic as "expected SubmitIncomplete"
  }
}

pub fn classify_submit_422_without_missing_is_invalid_test() {
  case classify_submit(422, "{\"complete\":false}") {
    SubmitInvalid(_) -> Nil
    _ -> panic as "expected SubmitInvalid"
  }
}

pub fn classify_submit_409_is_conflict_test() {
  let body = "{\"error\":\"invalid_status\",\"current_status\":\"submitted\"}"
  case classify_submit(409, body) {
    SubmitConflict(current) -> {
      assert current == "submitted"
    }
    _ -> panic as "expected SubmitConflict"
  }
}

pub fn classify_submit_409_without_body_uses_default_status_test() {
  case classify_submit(409, "not json") {
    SubmitConflict(current) -> {
      assert current == "submitted"
    }
    _ -> panic as "expected SubmitConflict"
  }
}

pub fn classify_submit_404_is_not_found_test() {
  case classify_submit(404, "{\"error\":\"request_not_found\"}") {
    SubmitNotFound -> Nil
    _ -> panic as "expected SubmitNotFound"
  }
}

pub fn classify_submit_500_is_server_error_test() {
  case classify_submit(500, "boom") {
    SubmitServerError(status, _) -> {
      assert status == 500
    }
    _ -> panic as "expected SubmitServerError"
  }
}

pub fn classify_submit_never_fakes_success_test() {
  // Whatever the server returns, the client must not report success
  // unless the status was 200.
  let cases = [400, 401, 403, 404, 409, 422, 500, 502, 503]
  list.each(cases, fn(status) {
    let outcome = classify_submit(status, "{}")
    let reported_success = case outcome {
      SubmitSucceeded(_) -> True
      _ -> False
    }
    assert reported_success == False
    Nil
  })
  Nil
}

// --- missing field decoding ----------------------------------------------

pub fn missing_field_decoder_reads_full_payload_test() {
  let body =
    "{\"field_name\":\"grant_number\",\"required\":true,\"conditional\":true,"
    <> "\"reason\":\"нужен при гранте\",\"clause_id\":\"demo-2.3\",\"quote\":\"текст\"}"
  let assert Ok(field) = json.parse(body, missing_field_decoder())
  assert field.field_name == "grant_number"
  assert field.required == True
  assert field.conditional == True
  assert field.reason == "нужен при гранте"
  assert field.clause_id == "demo-2.3"
  assert field.quote == "текст"
}

pub fn missing_field_decoder_defaults_test() {
  let assert Ok(field) =
    json.parse("{\"field_name\":\"x\"}", missing_field_decoder())
  assert field.field_name == "x"
  assert field.required == True
  assert field.conditional == False
  assert field.reason == ""
  assert field.clause_id == ""
  assert field.quote == ""
}

// --- request status -------------------------------------------------------

pub fn parse_status_known_values_test() {
  let draft: RequestStatus = parse_status("draft")
  let submitted: RequestStatus = parse_status("submitted")
  let in_progress: RequestStatus = parse_status("in_progress")
  let returned: RequestStatus = parse_status("returned")
  let completed: RequestStatus = parse_status("completed")
  assert draft == Draft
  assert submitted == Submitted
  assert in_progress == InProgress
  assert returned == Returned
  assert completed == Completed
}

pub fn parse_status_unknown_value_test() {
  assert parse_status("weird") == OtherStatus("weird")
}

pub fn status_to_string_roundtrip_test() {
  assert status_to_string(Draft) == "draft"
  assert status_to_string(Submitted) == "submitted"
  assert status_to_string(OtherStatus("weird")) == "weird"
}

// --- CJM screen map -------------------------------------------------------

pub fn parse_route_start_test() {
  assert parse_route("/") == screen_map.Route(screen_map.Start, None)
  assert parse_route("") == screen_map.Route(screen_map.Start, None)
}

pub fn parse_route_describe_test() {
  assert parse_route("/describe") == screen_map.Route(screen_map.Describe, None)
}

pub fn parse_route_request_test() {
  assert parse_route("/request/abc-123")
    == screen_map.Route(screen_map.Clarify("abc-123"), Some("abc-123"))
}

pub fn parse_route_unknown_falls_back_to_start_test() {
  assert parse_route("/nope") == screen_map.Route(screen_map.Start, None)
  assert parse_route("/request/") == screen_map.Route(screen_map.Start, None)
}

pub fn path_for_new_request_test() {
  assert path_for_new_request("abc") == "/request/abc"
}

pub fn path_for_each_screen_test() {
  assert path_for(screen_map.Start) == "/"
  assert path_for(screen_map.Describe) == "/describe"
  assert path_for(screen_map.Clarify("x")) == "/request/x"
  assert path_for(screen_map.Result("x")) == "/request/x"
}

pub fn screen_titles_are_distinct_test() {
  assert screen_title(screen_map.Start) != screen_title(screen_map.Describe)
  assert screen_title(screen_map.Clarify("x")) != screen_title(screen_map.Result("x"))
}

pub fn is_request_screen_test() {
  assert is_request_screen(screen_map.Clarify("x")) == True
  assert is_request_screen(screen_map.Result("x")) == True
  assert is_request_screen(screen_map.Start) == False
  assert is_request_screen(screen_map.Describe) == False
}

pub fn step_number_is_monotonic_test() {
  assert step_number(screen_map.Start) == 0
  assert step_number(screen_map.Describe) == 1
  assert step_number(screen_map.Clarify("x")) == 2
  assert step_number(screen_map.Result("x")) == 3
}

// --- fields: local hint only, never the authority ------------------------

pub fn field_specs_have_the_expected_order_test() {
  let specs = field_specs()
  let names = list.map(specs, fn(spec) { spec.name })
  assert names
    == [
      "destination_city",
      "purpose",
      "start_date",
      "end_date",
      "funding_source",
      "grant_number",
      "approver_id",
    ]
}

pub fn find_spec_by_name_test() {
  let specs = field_specs()
  case find_spec(specs, "destination_city") {
    Some(spec) -> {
      assert spec.required == True
      Nil
    }
    None -> panic as "expected a spec for destination_city"
  }
  case find_spec(specs, "does_not_exist") {
    Some(_) -> panic as "expected None"
    None -> Nil
  }
}

pub fn is_filled_rejects_empty_test() {
  assert is_filled("x") == True
  assert is_filled("") == False
}

pub fn locally_missing_lists_required_empty_fields_test() {
  let specs = field_specs()
  let values = dict.from_list([#("destination_city", "Казань")])
  let missing = locally_missing(specs, values)
  let names = list.map(missing, fn(spec) { spec.name })
  assert list.contains(names, "purpose")
  assert list.contains(names, "start_date")
  assert list.contains(names, "end_date")
  assert list.contains(names, "funding_source")
  assert list.contains(names, "approver_id")
  assert list.contains(names, "destination_city") == False
}

pub fn locally_missing_respects_conditional_rule_test() {
  let specs = field_specs()
  // The condition field is unknown, so the predicate cannot be proven
  // false. The module treats that conservatively: the conditional field
  // counts as missing. This matches the server-side rule.
  let without = locally_missing(specs, dict.new())
  assert list.contains(list.map(without, fn(spec) { spec.name }), "grant_number")
  // With "grant" the condition is definitively met.
  let with_grant = locally_missing(specs, dict.from_list([#("funding_source", "grant")]))
  assert list.contains(list.map(with_grant, fn(spec) { spec.name }), "grant_number")
  // With "budget" the condition is definitively false, so the conditional
  // field is not required.
  let with_budget = locally_missing(specs, dict.from_list([#("funding_source", "budget")]))
  assert list.contains(list.map(with_budget, fn(spec) { spec.name }), "grant_number") == False
}

pub fn locally_missing_is_empty_when_everything_is_filled_test() {
  let specs = field_specs()
  let values =
    dict.from_list([
      #("destination_city", "Казань"),
      #("purpose", "конференция"),
      #("start_date", "2026-11-12"),
      #("end_date", "2026-11-14"),
      #("funding_source", "budget"),
      #("approver_id", "boss"),
    ])
  assert locally_missing(specs, values) == []
}

