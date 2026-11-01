#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for verify_fixture_citations.py.

Run with:
    python -m unittest scripts.test_verify_fixture_citations
or:
    python scripts/test_verify_fixture_citations.py
"""
from __future__ import annotations

import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

# Make the sibling script importable when running directly.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_fixture_citations as v  # noqa: E402


def _fixture_valid() -> dict:
    return {
        "regulation": {
            "title": "Test",
            "version": "2025-01-01",
            "status": "approved",
            "source": {
                "act_kind": "Test Act",
                "number": "501",
                "date": "16 апреля 2025 г.",
                "publisher": "Test",
                "raw_text_source": "https://example.com",
            },
        },
        "clauses": [
            {"number": "2", "text": "Работники направляются в командировки."},
            {"number": "3", "text": "Срок командировки определяется работодателем."},
        ],
        "request_type": {
            "name": "Служебная командировка",
            "description": "Test",
            "enabled": False,
            "fields_schema": {"type": "object"},
        },
        "requirements": [
            {
                "field_name": "city",
                "required": True,
                "clause_id": "2",
                "quote": "Работники направляются в командировки.",
            },
            {
                "field_name": "duration",
                "required": True,
                "clause_id": "3",
                "quote": "Срок командировки определяется работодателем.",
            },
        ],
    }


class TestNormalizeWhitespace(unittest.TestCase):
    def test_collapses_runs_of_whitespace(self):
        self.assertEqual(v.normalize_whitespace("a   b\t c"), "a b c")

    def test_collapses_nbsp(self):
        # NBSP is U+00A0; we want to treat it as ordinary whitespace.
        self.assertEqual(v.normalize_whitespace("a\u00a0\u00a0b"), "a b")

    def test_strips_edges(self):
        self.assertEqual(v.normalize_whitespace("  hello  "), "hello")

    def test_preserves_punctuation_and_case(self):
        # We must NOT lowercase or remove punctuation — legal text comparison
        # is case-sensitive and punctuation-sensitive.
        self.assertEqual(
            v.normalize_whitespace("Срок командировки определяется Работодателем."),
            "Срок командировки определяется Работодателем.",
        )


class TestValidateFixtureHappyPath(unittest.TestCase):
    def test_valid_fixture_passes(self):
        passed, errors, warnings = v.validate_fixture(_fixture_valid())
        self.assertEqual(errors, [], f"unexpected errors: {errors}")
        self.assertGreaterEqual(passed, 1)

    def test_quote_with_extra_whitespace_inside_clause(self):
        # Fixture has clause with a single space between words; the quote has
        # multiple spaces. Normalization should make them match.
        data = _fixture_valid()
        data["requirements"][0]["quote"] = "Работники   направляются   в командировки."
        data["clauses"][0]["text"] = "Работники направляются в командировки."
        passed, errors, warnings = v.validate_fixture(data)
        self.assertEqual(errors, [], f"unexpected errors: {errors}")

    def test_clause_id_or_clause_number_both_accepted(self):
        # The validator must accept either `clause_id` or `clause_number`.
        data = _fixture_valid()
        data["requirements"][0].pop("clause_id")
        data["requirements"][0]["clause_number"] = "2"
        passed, errors, warnings = v.validate_fixture(data)
        self.assertEqual(errors, [], f"unexpected errors: {errors}")

    def test_clause_id_lookup_with_canonical_and_legacy(self):
        """Regression for the clause-id lookup bug: the validator must
        resolve `clause_id='p.N'` even when the fixture also has a
        `number='N'` field. Earlier versions only built the lookup from
        `number`, so any `clause_id` that didn't match a `number` raised
        'clause_id not found' even when the clause was clearly present.
        """
        data = _fixture_valid()
        data["clauses"] = [
            {"clause_id": "p.1", "number": "1",
             "text": "Работник направляется в командировку."},
            {"clause_id": "p.2", "number": "2",
             "text": "Срок устанавливает работодатель."},
        ]
        data["requirements"] = [
            {"field_name": "city", "required": True,
             "clause_id": "p.1", "quote": "в командировку"},
            {"field_name": "end_date", "required": True,
             "clause_number": "2", "quote": "Срок устанавливает"},
        ]
        passed, errors, warnings = v.validate_fixture(data)
        self.assertEqual(errors, [], f"unexpected errors: {errors}")
        self.assertGreaterEqual(passed, 2)


class TestValidateFixtureErrors(unittest.TestCase):
    def test_fabricated_quote_rejected(self):
        data = _fixture_valid()
        data["requirements"][0]["quote"] = "Эта цитата не существует в пункте 2."
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(
            any("not found verbatim" in e for e in errors),
            f"expected verbatim-not-found error, got: {errors}",
        )

    def test_invalid_clause_id_rejected(self):
        data = _fixture_valid()
        data["requirements"][0]["clause_id"] = "999"
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("not found in clauses" in e for e in errors))

    def test_empty_quote_rejected(self):
        data = _fixture_valid()
        data["requirements"][0]["quote"] = ""
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("quote is empty" in e for e in errors))

    def test_todo_quote_rejected(self):
        data = _fixture_valid()
        data["requirements"][0]["quote"] = "TODO: добавить цитату"
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("TODO placeholder" in e for e in errors))

    def test_missing_clause_rejected(self):
        data = _fixture_valid()
        data["requirements"][0]["clause_id"] = "999-NOT-EXIST"
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("not found in clauses" in e for e in errors))

    def test_word_order_matters(self):
        # We must NOT normalize word order. Legal citations are exact.
        data = _fixture_valid()
        data["requirements"][0]["quote"] = "направляются Работники в командировки."
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(
            any("not found verbatim" in e for e in errors),
            "word-order swap must not pass verbatim check",
        )

    def test_case_matters(self):
        # We must NOT lowercase. Legal text comparison is case-sensitive.
        data = _fixture_valid()
        data["requirements"][0]["quote"] = "работники направляются в командировки."
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(
            any("not found verbatim" in e for e in errors),
            "case-only change must not pass verbatim check",
        )

    def test_duplicate_clause_numbers_rejected(self):
        data = _fixture_valid()
        data["clauses"].append({"number": "2", "text": "Duplicate."})
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("duplicated" in e for e in errors))

    def test_duplicate_field_names_rejected(self):
        data = _fixture_valid()
        data["requirements"][1]["field_name"] = "city"
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("duplicated" in e for e in errors))

    def test_required_must_be_bool(self):
        data = _fixture_valid()
        data["requirements"][0]["required"] = "yes"  # not a bool
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("required must be a boolean" in e for e in errors))

    def test_empty_clauses_rejected(self):
        data = _fixture_valid()
        data["clauses"] = []
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("clauses must be a non-empty list" in e for e in errors))

    def test_missing_top_level_keys(self):
        data = _fixture_valid()
        del data["requirements"]
        passed, errors, warnings = v.validate_fixture(data)
        self.assertTrue(any("top-level keys missing" in e for e in errors))


class TestMain(unittest.TestCase):
    def _write_fixture(self, tmpdir: Path, data: dict) -> Path:
        p = tmpdir / "fixture.json"
        p.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return p

    def test_main_returns_0_on_valid(self):
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            fx = self._write_fixture(Path(td), _fixture_valid())
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = v.main(["--fixture", str(fx)])
            self.assertEqual(rc, 0, f"unexpected non-zero exit; output:\n{buf.getvalue()}")

    def test_main_returns_1_on_errors(self):
        import tempfile

        data = _fixture_valid()
        data["requirements"][0]["quote"] = "fabricated nonsense"
        with tempfile.TemporaryDirectory() as td:
            fx = self._write_fixture(Path(td), data)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = v.main(["--fixture", str(fx)])
            self.assertEqual(rc, 1)

    def test_main_json_output(self):
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            fx = self._write_fixture(Path(td), _fixture_valid())
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = v.main(["--fixture", str(fx), "--json"])
            self.assertEqual(rc, 0)
            payload = json.loads(buf.getvalue())
            self.assertIn("passed", payload)
            self.assertIn("errors", payload)
            self.assertIn("warnings", payload)
            self.assertTrue(payload["ok"])

    def test_main_returns_2_on_missing_fixture(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = v.main(["--fixture", "C:/nonexistent/fixture.json"])
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
