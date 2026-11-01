#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify citations in business_trip_fixture.json.

This script validates that every requirement's `quote` field appears verbatim
in the corresponding `clause` text, after normalizing only whitespace
differences (multiple spaces, tabs, NBSP, etc.). It does NOT use fuzzy
matching — legal citations must be exact.

It is a deterministic, dependency-free validator (stdlib only) so it can run
in CI and in pre-commit hooks without extra setup.

Usage:
    python scripts/verify_fixture_citations.py
    python scripts/verify_fixture_citations.py --fixture path/to/fixture.json
    python scripts/verify_fixture_citations.py --json   # machine-readable output

Exit codes:
    0  - all checks passed
    1  - validation errors found
    2  - usage / fixture loading error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


# Default fixture location relative to the project root.
DEFAULT_FIXTURE = Path(__file__).resolve().parents[1] / "database" / "seeds" / "business_trip_fixture.json"


def normalize_whitespace(s: str) -> str:
    """Normalize whitespace for citation comparison.

    Rules (intentionally narrow — we must not normalize legal text):
      - collapse runs of any whitespace characters (space, tab, NBSP, etc.)
        into a single regular space
      - strip leading/trailing whitespace

    Everything else (punctuation, case, word order) is preserved verbatim.
    """
    return re.sub(r"\s+", " ", s).strip()


def _fail(errors: list[str], msg: str) -> None:
    errors.append(msg)


def validate_fixture(data: dict[str, Any]) -> tuple[int, list[str], list[str]]:
    """Run all checks. Returns (counts_passed, errors, warnings).

    The script aggregates errors across the whole fixture so a single run
    reports everything that needs fixing at once.
    """
    errors: list[str] = []
    warnings: list[str] = []
    passed = 0

    # --- Top-level shape ---
    required_top = {"regulation", "clauses", "request_type", "requirements"}
    missing_top = required_top - set(data.keys())
    if missing_top:
        _fail(errors, f"top-level keys missing: {sorted(missing_top)}")
        return passed, errors, warnings
    passed += 1

    # --- Regulation ---
    reg = data["regulation"]
    src = reg.get("source", {})
    if not isinstance(src, dict):
        _fail(errors, "regulation.source must be an object")
    else:
        for key in ("act_kind", "number", "date", "publisher"):
            if not src.get(key):
                _fail(errors, f"regulation.source.{key} is empty")
        if not src.get("raw_text_source"):
            warnings.append(
                "regulation.source.raw_text_source is empty: citation provenance is unknown"
            )
    if reg.get("status") != "approved":
        warnings.append(
            f"regulation.status={reg.get('status')!r} (expected 'approved' for fixture to be usable)"
        )
    passed += 1

    # --- Clauses ---
    clauses = data["clauses"]
    if not isinstance(clauses, list) or not clauses:
        _fail(errors, "clauses must be a non-empty list")
    else:
        clause_numbers: list[str] = []
        seen_clause_numbers: set[str] = set()
        for i, c in enumerate(clauses):
            cnum = c.get("number")
            ctext = c.get("text", "")
            if not isinstance(cnum, str) or not cnum:
                _fail(errors, f"clauses[{i}].number is empty or not a string")
            elif cnum in seen_clause_numbers:
                _fail(errors, f"clauses[{i}].number={cnum!r} is duplicated")
            else:
                seen_clause_numbers.add(cnum)
                clause_numbers.append(cnum)
            if cnum == "TODO" or "TODO" in (ctext or ""):
                warnings.append(
                    f"clauses[{i}] is a TODO placeholder — fixture is not yet ready for production use"
                )
            if not isinstance(ctext, str) or not ctext.strip():
                _fail(errors, f"clauses[{i}].text is empty")
        passed += 1

    # --- request_type ---
    rt = data.get("request_type", {})
    if rt.get("enabled") is True:
        # If enabled, all requirements must be confirmed (no TODO).
        warnings.append(
            "request_type.enabled=True but citations are TODO — admin approval still required before use"
        )
    passed += 1

    # --- Requirements ---
    reqs = data.get("requirements", [])
    if not isinstance(reqs, list):
        _fail(errors, "requirements must be a list")
        return passed, errors, warnings

    if not reqs:
        _fail(errors, "requirements is empty")

    seen_field_names: set[str] = set()
    # Build lookup of clause text by canonical `clause_id` (preferred) and
    # legacy `number` (fallback). Both may be present in the same fixture;
    # in that case `clause_id` wins for the canonical key, and `number` is
    # kept as a separate legacy alias so old `clause_number` references
    # still resolve.
    clause_by_number: dict[str, str] = {}
    for c in clauses or []:
        if not isinstance(c, dict):
            continue
        cid = c.get("clause_id")
        if cid:
            clause_by_number[str(cid)] = c.get("text", "")
        num = c.get("number")
        if num and str(num) not in clause_by_number:
            clause_by_number[str(num)] = c.get("text", "")

    for i, r in enumerate(reqs):
        prefix = f"requirements[{i}]"

        # Required fields on each requirement.
        # Either `clause_id` or `clause_number` is acceptable as the clause
        # reference; `clause_id` is the canonical name. We only require the
        # canonical name in NEW fixtures (see warning below).
        for key in ("field_name", "required", "quote"):
            if key not in r:
                _fail(errors, f"{prefix}.{key} missing")
        if "clause_id" not in r and "clause_number" not in r:
            _fail(errors, f"{prefix}: either clause_id or clause_number is required")
        elif "clause_id" not in r:
            warnings.append(
                f"{prefix} uses clause_number (legacy field name); prefer clause_id in new fixtures"
            )

        field_name = r.get("field_name")
        if not isinstance(field_name, str) or not field_name.strip():
            _fail(errors, f"{prefix}.field_name is empty")
        elif field_name in seen_field_names:
            _fail(errors, f"{prefix}.field_name={field_name!r} is duplicated")
        else:
            seen_field_names.add(field_name)

        # required must be bool.
        if not isinstance(r.get("required"), bool):
            _fail(errors, f"{prefix}.required must be a boolean")

        clause_id = r.get("clause_id") or r.get("clause_number")
        quote = r.get("quote", "")
        if not isinstance(quote, str) or not quote.strip():
            _fail(errors, f"{prefix}.quote is empty")

        # TODO detection.
        if isinstance(quote, str) and ("TODO" in quote or quote.strip() == ""):
            _fail(errors, f"{prefix}.quote contains TODO placeholder")
            continue

        # Clause id must exist.
        if clause_id is None:
            _fail(errors, f"{prefix}.clause_id is empty")
            continue
        if clause_id not in clause_by_number:
            _fail(
                errors,
                f"{prefix}.clause_id={clause_id!r} not found in clauses "
                f"(known: {sorted(clause_by_number.keys())})",
            )
            continue

        # Quote must appear verbatim in clause text after whitespace normalization.
        clause_text = clause_by_number[clause_id]
        n_quote = normalize_whitespace(quote)
        n_clause = normalize_whitespace(clause_text)
        if n_quote not in n_clause:
            _fail(
                errors,
                f"{prefix}: quote not found verbatim in clause {clause_id!r} "
                f"(after whitespace normalization). "
                f"quote starts with: {n_quote[:80]!r}",
            )
            continue

        passed += 1

    # --- Cross-check: every enabled request_type requires at least one
    # confirmed requirement.
    if rt.get("enabled") is True and not any(
        isinstance(r, dict)
        and isinstance(r.get("quote"), str)
        and "TODO" not in r.get("quote", "")
        and r.get("quote", "").strip()
        for r in reqs
    ):
        _fail(errors, "request_type.enabled=True but no confirmed requirements exist")

    return passed, errors, warnings


def render_human(passed: int, errors: list[str], warnings: list[str]) -> str:
    lines: list[str] = []
    lines.append("=== Citation validator ===")
    lines.append(f"Passed checks : {passed}")
    lines.append(f"Errors        : {len(errors)}")
    lines.append(f"Warnings      : {len(warnings)}")
    if warnings:
        lines.append("")
        lines.append("--- Warnings ---")
        for w in warnings:
            lines.append(f"  ! {w}")
    if errors:
        lines.append("")
        lines.append("--- Errors ---")
        for e in errors:
            lines.append(f"  X {e}")
    return "\n".join(lines)


def render_json(passed: int, errors: list[str], warnings: list[str]) -> str:
    return json.dumps(
        {
            "passed": passed,
            "errors": errors,
            "warnings": warnings,
            "ok": len(errors) == 0,
        },
        ensure_ascii=False,
        indent=2,
    )


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument(
        "--fixture",
        type=Path,
        default=DEFAULT_FIXTURE,
        help=f"Path to fixture JSON (default: {DEFAULT_FIXTURE})",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of a human report",
    )
    args = p.parse_args(argv)

    if not args.fixture.exists():
        msg = f"fixture not found: {args.fixture}"
        if args.json:
            print(json.dumps({"ok": False, "fatal": msg}))
        else:
            print(f"FATAL: {msg}")
        return 2

    try:
        with args.fixture.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        msg = f"invalid JSON in {args.fixture}: {e}"
        if args.json:
            print(json.dumps({"ok": False, "fatal": msg}))
        else:
            print(f"FATAL: {msg}")
        return 2

    passed, errors, warnings = validate_fixture(data)

    if args.json:
        print(render_json(passed, errors, warnings))
    else:
        print(render_human(passed, errors, warnings))

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
