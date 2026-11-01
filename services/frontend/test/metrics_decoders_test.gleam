//// services/frontend/test/metrics_decoders_test.gleam
////
//// Regression tests for the three metric endpoints. They cover the same
//// contract as scripts/test_metrics_decoders.mjs (runnable on the host
//// without the docker stack) but exercise the production Gleam code
//// paths via `json.parse`.
////
//// Endpoints covered:
////   1. GET /api/v1/moderation/metrics   (phase7_client)
////   2. GET /api/v1/automation/metrics   (phase8_client)
////   3. GET /api/v1/automation/panel     (phase8_client — embedded metrics)
////
//// These tests are the regression gate for the metrics-parse bug fixed
//// by patch_metrics.py. If the contract changes, update the fixtures
//// AND the production decoders in the same commit.
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import effectivnost_360_lustre/phase7_client
import effectivnost_360_lustre/phase8_client
pub fn main() {
  gleeunit.main()
}
// -------------------------------------------------------------
// 1. GET /api/v1/moderation/metrics
// -------------------------------------------------------------
pub fn phase7_metrics_decodes_full_payload_test() {
  let payload =
    "{\"metrics\":["
    <> "{\"key\":\"time_to_first_action_hours\",\"label\":\"x\","
    <> "\"value\":4.5,\"unit\":\"h\",\"is_demo\":false},"
    <> "{\"key\":\"clarification_share\",\"label\":\"y\","
    <> "\"value\":null,\"unit\":\"%\",\"is_demo\":false}"
    <> "]}"
  let assert Ok(items) = json.parse(payload, phase7_client.metrics_decoder())
  assert list.length(items) == 2
  let assert Ok(first) = list.first(items)
  assert first.key == "time_to_first_action_hours"
  assert first.value == Some(4.5)
  let assert Ok(tail) = list.rest(items)
  let assert Ok(second) = list.first(tail)
  assert second.value == None
}
/// Regression: gleam_json 3.x encodes `3.0` as the JSON literal `3`. The
/// old `decode.optional(decode.float)` decoder rejected this. The patch
/// in services/frontend/src/effectivnost_360_lustre/phase7_client.gleam
/// widens the accepted types to int|float|null.
pub fn phase7_metrics_accepts_integer_literal_for_float_test() {
  let payload =
    "{\"metrics\":["
    <> "{\"key\":\"k\",\"label\":\"l\","
    <> "\"value\":3,\"unit\":\"h\",\"is_demo\":false}"
    <> "]}"
  let assert Ok(items) = json.parse(payload, phase7_client.metrics_decoder())
  let assert Ok(first) = list.first(items)
  assert first.value == Some(3.0)
}
pub fn phase7_metrics_missing_field_defaults_test() {
  let payload = "{\"metrics\":[{\"key\":\"k\"}]}"
  let assert Ok(items) = json.parse(payload, phase7_client.metrics_decoder())
  let assert Ok(first) = list.first(items)
  assert first.value == None
  assert first.label == ""
  assert first.unit == ""
  assert first.is_demo == False
}
// -------------------------------------------------------------
// 2. GET /api/v1/automation/metrics
// -------------------------------------------------------------
/// The frontend does not call this endpoint directly at the moment, but
/// the decoder (`parse_metrics`) MUST stay consistent with the backend
/// shape because phase8_client reuses it as a defensive parse.
pub fn phase8_metrics_decodes_string_values_test() {
  let payload =
    "{\"metrics\":["
    <> "{\"code\":\"auto_share\",\"label\":\"share\","
    <> "\"value\":\"66%\",\"delta\":\"\"}"
    <> "]}"
  let assert Ok(items) = phase8_client.parse_metrics(payload)
  assert list.length(items) == 1
  let assert Ok(first) = list.first(items)
  assert first.code == "auto_share"
  assert first.value == "66%"
}
/// The patch widens `value` to accept string|int|float|null.
pub fn phase8_metrics_accepts_numeric_value_test() {
  let payload =
    "{\"metrics\":["
    <> "{\"code\":\"x\",\"label\":\"y\",\"value\":42}"
    <> "]}"
  let assert Ok(items) = phase8_client.parse_metrics(payload)
  let assert Ok(first) = list.first(items)
  assert first.value == "42"
}
// -------------------------------------------------------------
// 3. GET /api/v1/automation/panel — embedded metrics (regression)
// -------------------------------------------------------------
/// Before the fix the frontend hard-coded `metrics: []` in panel_decoder,
/// so `load_efficiency_metrics` always returned an empty list and the
/// dashboard showed "Метрики пока не посчитаны".
pub fn phase8_panel_picks_up_embedded_metrics_test() {
  let payload =
    "{"
    <> "\"mode\":\"confirm\",\"mode_label\":\"label\",\"description\":\"\","
    <> "\"rules_version\":\"v1\","
    <> "\"checks\":[],\"exceptions\":[],\"tasks\":[],\"actions\":[],"
    <> "\"metrics\":["
    <> "{\"code\":\"checks_total\",\"label\":\"checks\",\"value\":\"12\",\"delta\":\"\"}"
    <> "]"
    <> "}"
  let assert Ok(panel) = phase8_client.parse_panel(payload)
  assert list.length(panel.metrics) == 1
  let assert Ok(first) = list.first(panel.metrics)
  assert first.code == "checks_total"
  assert first.value == "12"
}
/// Backward compatibility: an older panel payload without `metrics` MUST
/// still parse, defaulting to an empty list.
pub fn phase8_panel_without_metrics_defaults_to_empty_test() {
  let payload =
    "{"
    <> "\"mode\":\"manual\",\"mode_label\":\"manual\","
    <> "\"description\":\"\",\"rules_version\":\"v1\","
    <> "\"checks\":[],\"exceptions\":[],\"tasks\":[],\"actions\":[]"
    <> "}"
  let assert Ok(panel) = phase8_client.parse_panel(payload)
  assert panel.metrics == []
}