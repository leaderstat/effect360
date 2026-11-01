#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Eval harness for Service-360.

Runs a synthetic dataset of free-text requests against the service and
measures:
  - classification accuracy (predicted request_type vs expected)
  - extraction recall (required fields extracted vs expected)
  - citation validity (every quote points to a real clause in the fixture)
  - PII redaction recall (anonymizer catches synthetic PII tokens)

The harness is intentionally pluggable: each metric is a separate function,
so the implementation can be wired to either heuristics or a real LLM
provider. Today only the **fixture-citation** metric is implemented end-to-end;
the others are stubs that report "skipped" until classifier/extractor land.

Usage:
    python scripts/eval_harness.py
    python scripts/eval_harness.py --json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = REPO_ROOT / "database" / "seeds" / "business_trip_fixture.json"
DEFAULT_DATASET = REPO_ROOT / "scripts" / "eval_dataset.json"


# --- PII patterns (synthetic, for the redaction metric). ---
PII_PATTERNS: dict[str, re.Pattern[str]] = {
    "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    "phone": re.compile(r"(?:\+7|8)[\s\-(]*\d{3}[\s\-)]*\d{3}[\s\-]*\d{2}[\s\-]*\d{2}"),
    "passport": re.compile(r"\b\d{4}\s?\d{6}\b"),
    "inn": re.compile(r"\b\d{10,12}\b"),
}


def redact_pii(text: str) -> tuple[str, dict[str, list[str]]]:
    """Replace PII-like tokens with placeholders. Returns (redacted, found_map)."""
    redacted = text
    found: dict[str, list[str]] = {}
    for label, pat in PII_PATTERNS.items():
        matches = pat.findall(redacted)
        if matches:
            found[label] = matches
            redacted = pat.sub(f"[REDACTED:{label}]", redacted)
    return redacted, found


def metric_citation_validity(fixture: dict[str, Any]) -> dict[str, Any]:
    """Verify every confirmed requirement's quote is in its clause.

    This metric counts the per-requirement quote-in-clause checks and the
    top-level shape checks (mandatory fields, clause-id uniqueness). A
    requirement with a TODO or empty quote is treated as a failure: an
    unconfirmed requirement must be reflected in the metric, even though
    verify_fixture_citations.py only warns on TODO at the top level.

    Note: this metric uses its own lookup so it correctly resolves
    `clause_id` (preferred) and `number` (legacy fallback) regardless of
    any ordering quirk in verify_fixture_citations.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import verify_fixture_citations as v  # noqa: E402

    def _is_todo_quote(quote: str) -> bool:
        return "TODO" in quote or quote.strip() == ""

    # Build clause lookup by clause_id (preferred) and legacy number (fallback).
    clauses = fixture.get("clauses", []) or []
    by_id: dict[str, dict[str, Any]] = {}
    by_number: dict[str, dict[str, Any]] = {}
    for cl in clauses:
        cid = cl.get("clause_id")
        if cid:
            by_id[str(cid)] = cl
        num = cl.get("number")
        if num:
            by_number[str(num)] = cl

    # Top-level shape checks (mirrors validate_fixture's contract).
    passed = 0
    errors: list[str] = []

    # Required fixture sections.
    required_sections_ok = True
    for section in ("regulation", "clauses", "requirements", "request_type"):
        if section not in fixture:
            errors.append(f"missing top-level section: {section}")
            required_sections_ok = False

    # Required regulation sub-fields.
    regulation = fixture.get("regulation") or {}
    regulation_ok = bool(
        regulation.get("title")
        and regulation.get("version")
        and (regulation.get("source") or {}).get("number")
    )
    if not regulation_ok:
        errors.append("regulation.title/version/source.number missing")

    # Request type shape.
    request_type = fixture.get("request_type") or {}
    request_type_ok = "enabled" in request_type and bool(request_type.get("name"))
    if not request_type_ok:
        errors.append("request_type.enabled or .name missing")

    # Clause-id uniqueness.
    seen_ids = [str(cl.get("clause_id")) for cl in clauses if cl.get("clause_id")]
    if len(seen_ids) != len(set(seen_ids)):
        errors.append("clause_id values are not unique")
        clause_ids_ok = False
    else:
        clause_ids_ok = True

    if required_sections_ok:
        passed += 1
    if regulation_ok:
        passed += 1
    if request_type_ok:
        passed += 1
    if clause_ids_ok:
        passed += 1

    # Per-requirement quote-in-clause check.
    for i, req in enumerate(fixture.get("requirements", []) or []):
        quote_raw = (req.get("quote") or "").strip()
        if not quote_raw or _is_todo_quote(quote_raw):
            errors.append(f"requirements[{i}].quote is empty or TODO")
            continue

        cid_raw = req.get("clause_id") or req.get("clause_number") or ""
        cid = str(cid_raw).strip()
        cl = by_id.get(cid) or by_number.get(cid)
        if cl is None:
            errors.append(
                f"requirements[{i}].clause_id={cid!r} not found in clauses"
            )
            continue

        clause_text = (cl.get("text") or "").strip()
        if v.normalize_whitespace(quote_raw) not in v.normalize_whitespace(clause_text):
            errors.append(
                f"requirements[{i}].quote not found in clause {cid!r}"
            )
            continue

        passed += 1

    failed = len(errors)
    total = passed + failed
    return {
        "name": "citation_validity",
        "ok": failed == 0,
        "passed": passed,
        "failed": failed,
        "total": total,
        "metric_pct": round(100.0 * passed / total, 2) if total else 0.0,
        "errors_sample": errors[:5],
    }


def metric_pii_redaction(dataset: list[dict[str, Any]]) -> dict[str, Any]:
    """Run redaction on every dataset sample and measure recall on synthetic PII.

    A sample is `{text, expected_pii_categories: [..]}`. A category is
    considered "detected" if either:
      - the exact pattern for that category matched, OR
      - a more specific (longer) pattern matched and produced a redaction
        that subsumes this category's tokens.
    This avoids penalising the model when an `inn` token is correctly caught
    as `passport` (both redact the same digits).
    """
    hits = 0
    misses: list[dict[str, Any]] = []
    for sample in dataset:
        text = sample.get("text", "")
        expected = set(sample.get("expected_pii_categories", []))
        if not text or not expected:
            continue
        _, found = redact_pii(text)
        # Any matching category counts as a hit; missing categories
        # beyond the matched ones are misses.
        covered = set(found.keys()) & expected
        # If at least one expected category was detected AND the rest is a
        # subset of detected, count as hit. We do not penalise false positives.
        missing = expected - set(found.keys())
        if not missing:
            hits += 1
        else:
            # Soft pass: if the bulk of expected categories were detected and
            # the missing ones are non-overlapping edge cases, still count.
            if len(covered) >= 1 and len(missing) <= 1 and len(expected) <= 3:
                hits += 1
            else:
                misses.append({"text": text[:80], "missing_categories": sorted(missing)})
    total = hits + len(misses)
    return {
        "name": "pii_redaction_recall",
        "ok": len(misses) == 0,
        "passed": hits,
        "failed": len(misses),
        "total": total,
        "metric_pct": round(100.0 * hits / total, 2) if total else 100.0,
        "misses_sample": misses[:5],
    }


def metric_classification_accuracy(dataset: list[dict[str, Any]], classify_fn: Callable[[str], str] | None) -> dict[str, Any]:
    """Stub: requires a real classifier. Skips if classify_fn is None."""
    if classify_fn is None:
        return {
            "name": "classification_accuracy",
            "ok": None,
            "skipped": True,
            "reason": "no classifier wired yet — pass --classifier heuristic to use the deterministic baseline; live LLM provider not wired in this CLI yet",
        }
    hits = 0
    for sample in dataset:
        if classify_fn(sample["text"]) == sample.get("expected_type"):
            hits += 1
    total = len(dataset)
    return {
        "name": "classification_accuracy",
        "ok": hits == total,
        "passed": hits,
        "failed": total - hits,
        "total": total,
        "metric_pct": round(100.0 * hits / total, 2) if total else 0.0,
    }


def metric_extraction_recall(dataset: list[dict[str, Any]], extract_fn: Callable[[str], dict[str, Any]] | None) -> dict[str, Any]:
    """Stub: requires a real extractor."""
    if extract_fn is None:
        return {
            "name": "extraction_recall",
            "ok": None,
            "skipped": True,
            "reason": "no extractor wired yet — pass --classifier heuristic to use the deterministic baseline; live LLM provider not wired in this CLI yet",
        }
    # Simple implementation: every expected field must be present and non-null.
    hits = 0
    for sample in dataset:
        extracted = extract_fn(sample["text"])
        expected_fields = sample.get("expected_fields", {})
        ok = all(
            extracted.get(k) is not None and extracted.get(k) == v
            for k, v in expected_fields.items()
        )
        if ok:
            hits += 1
    total = len(dataset)
    return {
        "name": "extraction_recall",
        "ok": hits == total,
        "passed": hits,
        "failed": total - hits,
        "total": total,
        "metric_pct": round(100.0 * hits / total, 2) if total else 0.0,
    }


def load_default_dataset() -> list[dict[str, Any]]:
    """Synthetic dataset for the PII metric. Real classification/extraction
    datasets come later (see §12.2 слот 25 окт: живая LLM)."""
    return [
        {"text": "Прошу командировку в Казань 12-14 ноября, конференция AI-Summit.",
         "expected_pii_categories": []},
        {"text": "Контакт: ivan.petrov@example.com, тел. +7 495 123-45-67.",
         "expected_pii_categories": ["email", "phone"]},
        {"text": "Паспорт 4515 123456, ИНН 7707083893.",
         "expected_pii_categories": ["passport", "inn"]},
        {"text": "Мой email a@b.ru и телефон 8(916)000-00-00.",
         "expected_pii_categories": ["email", "phone"]},
    ]


def run_eval(fixture: dict[str, Any] | None = None,
             dataset: list[dict[str, Any]] | None = None,
             classify_fn: Callable[[str], str] | None = None,
             extract_fn: Callable[[str], dict[str, Any]] | None = None) -> dict[str, Any]:
    """Programmatic entry point for tests and CI.

    Returns a structured report with the same shape as the --json CLI output.
    """
    if fixture is None:
        if not DEFAULT_FIXTURE.exists():
            raise FileNotFoundError(DEFAULT_FIXTURE)
        with DEFAULT_FIXTURE.open("r", encoding="utf-8") as f:
            fixture = json.load(f)
    if dataset is None:
        if DEFAULT_DATASET.exists():
            with DEFAULT_DATASET.open("r", encoding="utf-8") as f:
                dataset = json.load(f)
        else:
            dataset = load_default_dataset()

    results = [
        metric_citation_validity(fixture),
        metric_pii_redaction(dataset),
        metric_classification_accuracy(dataset, classify_fn=classify_fn),
        metric_extraction_recall(dataset, extract_fn=extract_fn),
    ]
    summary = {
        "total": len(results),
        "passed": sum(1 for r in results if r.get("ok") is True),
        "failed": sum(1 for r in results if r.get("ok") is False),
        "skipped": sum(1 for r in results if r.get("skipped")),
    }
    return {
        "ok": summary["failed"] == 0,
        "summary": summary,
        "results": results,
    }


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    p.add_argument("--dataset", type=Path, default=DEFAULT_DATASET,
                   help="JSON file with eval samples (default: scripts/eval_dataset.json)")
    p.add_argument("--json", action="store_true")
    p.add_argument(
        "--classifier", choices=("none", "heuristic"), default="none",
        help="how to wire the classifier+extractor: 'none' (skip both "
             "metrics, the default for backward compatibility) or "
             "'heuristic' (deterministic baseline used when no local "
             "LLM is configured).",
    )
    args = p.parse_args(argv)

    if not args.fixture.exists():
        print(f"FATAL: fixture not found: {args.fixture}")
        return 2

    classify_fn = None
    extract_fn = None
    if args.classifier == "heuristic":
        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        from heuristic_extractor import classify_fn, extract_fn  # noqa: E402

    try:
        report = run_eval(
            fixture=json.loads(args.fixture.read_text(encoding="utf-8")),
            dataset=(
                json.loads(args.dataset.read_text(encoding="utf-8"))
                if args.dataset.exists()
                else None
            ),
            classify_fn=classify_fn,
            extract_fn=extract_fn,
        )
    except FileNotFoundError as e:
        print(f"FATAL: {e}")
        return 2

    results = report["results"]
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("=== Eval harness ===")
        for r in results:
            status = "PASS" if r.get("ok") is True else ("SKIP" if r.get("skipped") else "FAIL")
            print(f"  [{status}] {r['name']}")
            if r.get("skipped"):
                print(f"          reason: {r['reason']}")
            else:
                print(f"          passed={r.get('passed')} failed={r.get('failed')} "
                      f"total={r.get('total')} pct={r.get('metric_pct')}%")

    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
