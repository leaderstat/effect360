// scripts/test_metrics_decoders.mjs
//
// Regression tests for the three metric endpoints.
//
// These tests do NOT depend on the docker stack. They pin the contract of
// each endpoint by feeding representative JSON payloads through pure
// decoders that mirror the production code in
//   services/frontend/src/effectivnost_360_lustre/phase7_client.gleam
//   services/frontend/src/effectivnost_360_lustre/phase8_client.gleam
// If you change the production decoders, you MUST mirror the change here
// or the contract drift will silently break the dashboard.
//
// Endpoint matrix:
//   1. GET /api/v1/moderation/metrics
//      payload: { metrics: [{ key, label, value: number|null, unit, is_demo }] }
//   2. GET /api/v1/automation/metrics
//      payload: { counters: { ...int }, metrics: [{ code, label, value: string, delta: string }] }
//   3. GET /api/v1/automation/panel
//      payload: { ..., checks, exceptions, tasks, actions, metrics: [{ code, label, value, delta }] }
//
// Backend sources:
//   services/api/src/effectivnost_360/moderation_router.gleam        (1)
//   services/api/src/effectivnost_360/automation_router.gleam        (2, 3)
//
// We keep the decoders here in plain JS so the test runs without gleam on
// the host. The decoders MUST stay byte-for-byte equivalent to the
// `.gleam` source in semantics (type erasure aside).
//
// Run:  node scripts/test_metrics_decoders.mjs

import assert from "node:assert/strict";

// ---------------- shared decoder plumbing ----------------
class DecodeError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

// `decode.field(name, decoder)` walks the object and applies the inner
// decoder. `decode.optional_field(name, default, decoder)` does the same
// but returns the default when the field is missing.
function field(name, inner) {
  return (obj) => {
    if (obj === null || typeof obj !== "object" || !(name in obj)) {
      throw new DecodeError(`missing field: ${name}`);
    }
    return inner(obj[name]);
  };
}

function optionalField(name, defaultValue, inner) {
  return (obj) => {
    if (obj === null || typeof obj !== "object" || !(name in obj)) {
      return defaultValue;
    }
    return inner(obj[name]);
  };
}

function listOf(inner) {
  return (arr) => {
    if (!Array.isArray(arr)) {
      throw new DecodeError("expected list");
    }
    return arr.map((v) => inner(v));
  };
}

const decoders = {
  string: (v) => {
    if (typeof v !== "string") throw new DecodeError("expected string");
    return v;
  },
  int: (v) => {
    if (typeof v !== "number" || !Number.isInteger(v)) {
      throw new DecodeError("expected int");
    }
    return v;
  },
  float: (v) => {
    if (typeof v !== "number") throw new DecodeError("expected float");
    return v;
  },
  bool: (v) => {
    if (typeof v !== "boolean") throw new DecodeError("expected bool");
    return v;
  },
  optional: (inner) => (v) => {
    if (v === null || v === undefined) return null;
    return inner(v);
  },
};

// ---------------- Endpoint 1: /api/v1/moderation/metrics (Phase 7) ----------------
// Backend: json.float(v) for some, json.null() for "no data".
// Frontend: phase7_client.metric_decoder with the patch from
// patch_metrics.py now accepts int|float|null.
const phase7MetricValue = decoders.optional((v) => {
  if (typeof v === "number") return v;
  throw new DecodeError("expected number");
});
const phase7MetricDecoder = (obj) => {
  const key = field("key", decoders.string)(obj);
  const label = optionalField("label", "", decoders.string)(obj);
  const value = optionalField("value", null, phase7MetricValue)(obj);
  const unit = optionalField("unit", "", decoders.string)(obj);
  const is_demo = optionalField("is_demo", false, decoders.bool)(obj);
  return { key, label, value, unit, is_demo };
};
const phase7MetricsListDecoder = (obj) =>
  listOf(phase7MetricDecoder)(optionalField("metrics", [], (v) => v)(obj));

// ---------------- Endpoint 2: /api/v1/automation/metrics (Phase 8 /agent metrics) ----------------
// Backend: counters are JSON ints; derived metrics use json.string for value.
// Frontend: phase8_client.metrics_list_decoder with the patch tolerates
// string|int|float|null for `value`.
const metricValueDecoder = (v) => {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isInteger(v)) return String(v);
  if (typeof v === "number") return String(Math.round(v));
  throw new DecodeError("expected scalar");
};
const phase8MetricDecoder = (obj) => {
  const code = field("code", decoders.string)(obj);
  const label = field("label", decoders.string)(obj);
  const value = field("value", metricValueDecoder)(obj);
  const delta = optionalField("delta", "", decoders.string)(obj);
  return { code, label, value, delta };
};
const phase8MetricsListDecoder = (obj) =>
  field("metrics", listOf(phase8MetricDecoder))(obj);

// ---------------- Endpoint 3: /api/v1/automation/panel (Phase 8 panel) ----------------
// Frontend: phase8_client.panel_decoder. With the fix, `metrics` is
// decoded from the embedded payload (optional, defaulting to []).
const phase8PanelDecoder = (obj) => {
  const mode = field("mode", decoders.string)(obj);
  const mode_label = field("mode_label", decoders.string)(obj);
  const description = field("description", decoders.string)(obj);
  const rules_version = field("rules_version", decoders.string)(obj);
  const checks = field("checks", listOf((_) => ({})))(obj);
  const exceptions = field("exceptions", listOf((_) => ({})))(obj);
  const tasks = field("tasks", listOf((_) => ({})))(obj);
  const actions = field("actions", listOf((_) => ({})))(obj);
  const metrics = optionalField("metrics", [], listOf(phase8MetricDecoder))(obj);
  return {
    mode,
    mode_label,
    description,
    rules_version,
    checks,
    exceptions,
    tasks,
    actions,
    metrics,
  };
};

// ---------------- Test cases ----------------
const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

// === Endpoint 1 ===
test("phase7/metrics: full payload with floats and nulls", () => {
  const payload = {
    metrics: [
      {
        key: "time_to_first_action_hours",
        label: "Время до первого действия модератора",
        value: 4.5,
        unit: "ч",
        is_demo: false,
      },
      {
        key: "clarification_share",
        label: "Доля заявок, требующих уточнения",
        value: null,
        unit: "%",
        is_demo: false,
      },
    ],
  };
  const out = phase7MetricsListDecoder(payload);
  assert.equal(out.length, 2);
  assert.equal(out[0].key, "time_to_first_action_hours");
  assert.equal(out[0].value, 4.5);
  assert.equal(out[1].value, null);
});

test("phase7/metrics: backend emits integer literal for whole-number floats", () => {
  // Regression: gleam_json encodes 3.0 as the JSON literal `3`. The old
  // decoder rejected this with "expected float". The new one accepts.
  const payload = {
    metrics: [{ key: "k", label: "L", value: 3, unit: "ч", is_demo: false }],
  };
  const out = phase7MetricsListDecoder(payload);
  assert.equal(out[0].value, 3);
});

test("phase7/metrics: empty array stays empty", () => {
  assert.deepEqual(phase7MetricsListDecoder({}), []);
  assert.deepEqual(phase7MetricsListDecoder({ metrics: [] }), []);
});

test("phase7/metrics: missing optional fields default", () => {
  const payload = { metrics: [{ key: "k" }] };
  const out = phase7MetricsListDecoder(payload);
  assert.equal(out[0].label, "");
  assert.equal(out[0].value, null);
  assert.equal(out[0].unit, "");
  assert.equal(out[0].is_demo, false);
});

// === Endpoint 2 ===
test("phase8/automation-metrics: counters and metrics both decoded", () => {
  const payload = {
    counters: { checks_total: 12, checks_passed: 8 },
    metrics: [
      {
        code: "auto_share",
        label: "Доля автопроверок",
        value: "66%",
        delta: "",
      },
    ],
  };
  const items = phase8MetricsListDecoder(payload);
  assert.equal(items.length, 1);
  assert.equal(items[0].value, "66%");
});

test("phase8/automation-metrics: numeric value is coerced to string", () => {
  // Defensive: a future endpoint may emit JSON numbers. The UI is text-only.
  const items = phase8MetricsListDecoder({
    metrics: [{ code: "x", label: "y", value: 42 }],
  });
  assert.equal(items[0].value, "42");
});

test("phase8/automation-metrics: missing required field fails loudly", () => {
  assert.throws(
    () => phase8MetricsListDecoder({ metrics: [{ label: "x" }] }),
    DecodeError,
  );
});

// === Endpoint 3 ===
test("phase8/panel: embedded metrics are picked up (regression)", () => {
  const payload = {
    mode: "confirm",
    mode_label: "С подтверждением",
    description: "",
    rules_version: "v1",
    checks: [],
    exceptions: [],
    tasks: [],
    actions: [],
    metrics: [
      { code: "checks_total", label: "Всего проверок", value: "12", delta: "" },
    ],
  };
  const out = phase8PanelDecoder(payload);
  assert.equal(out.metrics.length, 1);
  assert.equal(out.metrics[0].code, "checks_total");
  assert.equal(out.metrics[0].value, "12");
});

test("phase8/panel: missing metrics field defaults to [] (backward-compat)", () => {
  const payload = {
    mode: "confirm",
    mode_label: "С подтверждением",
    description: "",
    rules_version: "v1",
    checks: [],
    exceptions: [],
    tasks: [],
    actions: [],
    // no metrics key at all
  };
  const out = phase8PanelDecoder(payload);
  assert.deepEqual(out.metrics, []);
});

// ---------------- Run ----------------
let passed = 0;
let failed = 0;
const failures = [];
for (const t of tests) {
  try {
    t.fn();
    console.log(`  ok   ${t.name}`);
    passed++;
  } catch (e) {
    console.log(`  FAIL ${t.name} :: ${e.message}`);
    failures.push({ name: t.name, error: e.message });
    failed++;
  }
}
console.log("");
console.log(`===== METRICS DECODER TESTS =====`);
console.log(`passed: ${passed}, failed: ${failed}`);
if (failed > 0) {
  console.log("failures:");
  for (const f of failures) console.log(`  - ${f.name}: ${f.error}`);
  process.exit(1);
}
process.exit(0);