#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Live eval against a real local LLM provider.

Runs the eval_dataset.json samples through an HTTP provider (Ollama or
OpenAI-compatible), measures classification accuracy and extraction recall,
and writes a structured JSON report. Falls back to "skipped" if the provider
is unreachable so the rest of CI is not blocked.

This is NOT a mock. It is a reproducible live-eval driver that ONLY
proceeds when the provider is reachable; otherwise it returns exit code 0
with `ok=false` and a `reason="provider_unreachable"` field so CI can
distinguish "tried, failed" from "skipped intentionally".

Contract (mirrors the heuristic baseline in eval_harness.py):
  - input:  --fixture (default database/seeds/demo_synthetic_fixture.json)
            --dataset (default scripts/eval_dataset.json)
            --provider {ollama|openai}  (default ollama)
            --base-url, --model, --api-key, --timeout, --temperature
  - output: structured JSON report with `metrics.classification_accuracy`
            and `metrics.extraction_recall`, identical shape to the
            heuristic report so CI can compare.
  - exit:   0 = provider reachable and call returned a parseable payload
            2 = config error
            3 = provider reachable but response invalid (real LLM failure)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = REPO_ROOT / "database" / "seeds" / "demo_synthetic_fixture.json"
DEFAULT_DATASET = REPO_ROOT / "scripts" / "eval_dataset.json"


# --- Provider adapters ------------------------------------------------------


def _post_json(url: str, body: dict[str, Any], headers: dict[str, str],
               timeout: float) -> dict[str, Any]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def call_ollama(base_url: str, model: str, prompt: str,
                temperature: float, timeout: float) -> str:
    url = f"{base_url.rstrip('/')}/api/chat"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": temperature},
    }
    resp = _post_json(url, body, {"Content-Type": "application/json"}, timeout)
    return str(resp["message"]["content"])


def call_openai(base_url: str, model: str, prompt: str,
                api_key: str, temperature: float, timeout: float) -> str:
    url = f"{base_url.rstrip('/')}/v1/chat/completions"
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": temperature,
    }
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    resp = _post_json(url, body, headers, timeout)
    return str(resp["choices"][0]["message"]["content"])


# --- Prompt + parse ---------------------------------------------------------


SYSTEM_PROMPT = (
    "Ты — классификатор и извлекатель полей для внутренней заявки. "
    "Ответь строго одним JSON-объектом без пояснений. Схема: "
    '{"type": <"business_trip"|"other">, "fields": {"city": <string|null>, '
    '"date_from": <string|null>, "date_to": <string|null>, '
    '"grant_number": <string|null>, "purpose": <string|null>, '
    '"funding": <"budget"|"grant"|null>}}'
)


def parse_response(raw: str) -> dict[str, Any] | None:
    """Parse the JSON object from a raw LLM response.

    Tolerates code-fences and stray prose; rejects everything that is not
    a single JSON object matching the schema.
    """
    if not raw:
        return None
    text = raw.strip()
    # Strip code fences if present.
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    # Find the outermost JSON object.
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < 0 or end <= start:
        return None
    try:
        obj = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None
    if "type" not in obj or "fields" not in obj or not isinstance(obj["fields"], dict):
        return None
    return obj


# --- Metrics ----------------------------------------------------------------


def metric_classification(dataset: list[dict[str, Any]],
                          call: Any) -> dict[str, Any]:
    hits = 0
    misses: list[dict[str, Any]] = []
    for sample in dataset:
        text = sample.get("text", "")
        if not text:
            continue
        try:
            raw = call(text)
            parsed = parse_response(raw)
        except Exception as e:  # network, timeout, schema
            misses.append({"text": text[:80], "error": f"{type(e).__name__}: {e}"})
            continue
        if parsed is None:
            misses.append({"text": text[:80], "error": "invalid_json"})
            continue
        if parsed.get("type") == sample.get("expected_type"):
            hits += 1
        else:
            misses.append({
                "text": text[:80],
                "got": parsed.get("type"),
                "expected": sample.get("expected_type"),
            })
    total = hits + len(misses)
    return {
        "name": "classification_accuracy",
        "ok": len(misses) == 0,
        "passed": hits,
        "failed": len(misses),
        "total": total,
        "metric_pct": round(100.0 * hits / total, 2) if total else 0.0,
        "errors_sample": misses[:5],
    }


def metric_extraction(dataset: list[dict[str, Any]], call: Any) -> dict[str, Any]:
    hits = 0
    misses: list[dict[str, Any]] = []
    for sample in dataset:
        text = sample.get("text", "")
        if not text:
            continue
        try:
            raw = call(text)
            parsed = parse_response(raw)
        except Exception as e:
            misses.append({"text": text[:80], "error": f"{type(e).__name__}: {e}"})
            continue
        if parsed is None:
            misses.append({"text": text[:80], "error": "invalid_json"})
            continue
        extracted = parsed.get("fields", {})
        expected_fields = sample.get("expected_fields", {})
        ok = all(
            extracted.get(k) is not None and extracted.get(k) == v
            for k, v in expected_fields.items()
        )
        if ok:
            hits += 1
        else:
            misses.append({
                "text": text[:80],
                "extracted": extracted,
                "expected": expected_fields,
            })
    total = hits + len(misses)
    return {
        "name": "extraction_recall",
        "ok": len(misses) == 0,
        "passed": hits,
        "failed": len(misses),
        "total": total,
        "metric_pct": round(100.0 * hits / total, 2) if total else 0.0,
        "errors_sample": misses[:5],
    }


# --- Driver -----------------------------------------------------------------


def probe(base_url: str, timeout: float) -> tuple[bool, str]:
    """Check provider reachability without committing to a model.

    For Ollama: GET /api/tags
    For OpenAI-compatible: GET /v1/models (best-effort)
    """
    for path in ("/api/tags", "/v1/models"):
        try:
            url = f"{base_url.rstrip('/')}{path}"
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8")[:500]
                return True, body
        except urllib.error.HTTPError as e:
            # 4xx means the server is up but the path is wrong; 404 is fine
            # for OpenAI-compat when probing /api/tags. Don't treat as down.
            if 400 <= e.code < 500:
                return True, f"http_status={e.code} path={path}"
            continue
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
        except Exception as e:
            continue
    return False, f"no response on /api/tags and /v1/models within {timeout}s"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    p.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    p.add_argument("--provider", choices=("ollama", "openai"), default="ollama")
    p.add_argument("--base-url", default=os.environ.get(
        "LOCAL_LLM_BASE_URL", "http://host.docker.internal:11434"))
    p.add_argument("--model", default=os.environ.get(
        "LOCAL_LLM_MODEL", "devstral-small-2:latest"))
    p.add_argument("--api-key", default=os.environ.get("LOCAL_LLM_API_KEY", ""))
    p.add_argument("--timeout", type=float, default=30.0)
    p.add_argument("--temperature", type=float, default=0.1)
    p.add_argument("--out", type=Path,
                   default=Path("scripts/live_eval_report.json"))
    args = p.parse_args(argv)

    # 1) Probe provider.
    t0 = time.monotonic()
    reachable, probe_info = probe(args.base_url, args.timeout)
    if not reachable:
        report = {
            "ok": False,
            "skipped": True,
            "reason": "provider_unreachable",
            "probe": probe_info,
            "provider": args.provider,
            "base_url": args.base_url,
            "model": args.model,
        }
        args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2),
                            encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False))
        return 0  # not a CI failure: provider is simply not available

    # 2) Wire call.
    if args.provider == "ollama":
        def call(text: str) -> str:
            return call_ollama(args.base_url, args.model,
                               f"{SYSTEM_PROMPT}\n\nТекст: {text}",
                               args.temperature, args.timeout)
    else:
        def call(text: str) -> str:
            return call_openai(args.base_url, args.model,
                               f"{SYSTEM_PROMPT}\n\nТекст: {text}",
                               args.api_key, args.temperature, args.timeout)

    # 3) Load dataset.
    if not args.dataset.exists():
        print(f"FATAL: dataset not found: {args.dataset}", file=sys.stderr)
        return 2
    dataset = json.loads(args.dataset.read_text(encoding="utf-8"))

    # 4) Run metrics.
    classification = metric_classification(dataset, call)
    extraction = metric_extraction(dataset, call)
    latency_ms = round((time.monotonic() - t0) * 1000, 2)

    # 5) Compose report.
    report = {
        "ok": classification["ok"] and extraction["ok"],
        "skipped": False,
        "provider": args.provider,
        "base_url": args.base_url,
        "model": args.model,
        "temperature": args.temperature,
        "total_latency_ms": latency_ms,
        "fixture": str(args.fixture.relative_to(REPO_ROOT)),
        "dataset": str(args.dataset.relative_to(REPO_ROOT)),
        "metrics": {
            "classification_accuracy": classification,
            "extraction_recall": extraction,
        },
    }

    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2),
                        encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["ok"] else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
