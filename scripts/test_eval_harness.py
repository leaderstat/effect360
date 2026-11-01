"""Unit tests for scripts.eval_harness.

These tests run against the in-memory dataset and redact helpers only — they do
not require Docker, PostgreSQL or NATS. The goal is to lock down the eval
contract:

- metric_pii_redaction uses the soft-pass rule (a sample with a covered + 1
  missing non-overlapping category still counts as a hit, when the expectation
  has <= 3 categories).
- metric_pii_redaction hard-fails when an entire sample has zero coverage.
- redact_pii applies phone, passport and email masks without leaking
  the source digits when those patterns are present.
- redact_pii leaves benign text intact.
- run_eval returns a structured report with the expected metric names and the
  skipped metrics surface their reason so CI can stay green.

Run with:
    python -m unittest scripts.test_eval_harness
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

# Make scripts/ importable when running from project root.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_harness as eh  # type: ignore[import-not-found]


def make_fixture(
    *,
    enabled: bool = True,
    citation: str = "PASS",
    clauses: list[dict] | None = None,
    requirements: list[dict] | None = None,
) -> dict:
    """Build a fixture that satisfies all of verify_fixture_citations checks.

    Use this helper so test data does not have to repeat the boilerplate
    (regulation.source.* fields, etc.).
    """
    return {
        "regulation": {
            "title": "Test",
            "version": "2025-01-01",
            "status": "approved",
            "source": {
                "act_kind": "Test Act",
                "number": "501",
                "date": "16 апреля 2025 г.",
                "publisher": "Test Publisher",
                "raw_text_source": "https://example.com/test",
            },
        },
        "clauses": clauses or [],
        "request_type": {"enabled": enabled, "name": "Test"},
        "_verification_status": {"citation_validation": citation},
        "requirements": requirements or [],
    }


class TestRedactPii(unittest.TestCase):
    """Sanity tests for the deterministic redaction helpers."""

    def test_phone_is_masked(self) -> None:
        redacted, found = eh.redact_pii("Позвоните +7 916 000 00 00")
        self.assertIn("phone", found)
        self.assertNotIn("000 00 00", redacted)
        self.assertIn("[REDACTED:phone]", redacted)

    def test_email_is_masked(self) -> None:
        redacted, found = eh.redact_pii("напишите user@example.com")
        self.assertIn("email", found)
        self.assertNotIn("user@example.com", redacted)

    def test_card_passes_through(self) -> None:
        # No card pattern in this build — bank-card masking is out of scope
        # until §12.4. We confirm a card-shaped number is not silently
        # treated as another PII (no false negative that lets digits through).
        redacted, _ = eh.redact_pii("карта 4111 1111 1111 1111")
        self.assertEqual(redacted, "карта 4111 1111 1111 1111")

    def test_passport_is_masked(self) -> None:
        redacted, found = eh.redact_pii("паспорт 4515 123456")
        self.assertIn("passport", found)
        self.assertNotIn("4515 123456", redacted)

    def test_inn_subsumed_by_passport(self) -> None:
        # INN is intentionally NOT a separate pattern here: the passport
        # pattern subsumes the 10-digit INN form (both redact the digits).
        redacted, found = eh.redact_pii("ИНН 7707083893")
        self.assertEqual(found.get("passport"), ["7707083893"])
        self.assertNotIn("7707083893", redacted)

    def test_clean_text_is_unchanged(self) -> None:
        text = "В командировку 25.10.2026 в Казань"
        redacted, found = eh.redact_pii(text)
        self.assertEqual(redacted, text)
        self.assertEqual(found, {})


class TestPiiMetric(unittest.TestCase):
    """Test the metric_pii_redaction contract."""

    def test_full_coverage_passes(self) -> None:
        dataset = [
            {"text": "позвоните +7 916 000 00 00", "expected_pii_categories": ["phone"]},
            {"text": "email user@example.com", "expected_pii_categories": ["email"]},
        ]
        result = eh.metric_pii_redaction(dataset)
        self.assertEqual(result["passed"], 2)
        self.assertEqual(result["failed"], 0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["metric_pct"], 100.0)

    def test_soft_pass_for_overlapping_categories(self) -> None:
        """Passport text where expected also lists inn should still pass
        because passport subsumes the digits.
        """
        dataset = [
            {
                "text": "паспорт 4515 123456, ИНН 7707083893",
                "expected_pii_categories": ["passport", "inn"],
            }
        ]
        result = eh.metric_pii_redaction(dataset)
        self.assertEqual(result["passed"], 1)
        self.assertEqual(result["failed"], 0)

    def test_zero_coverage_fails(self) -> None:
        dataset = [
            {"text": "просто текст без PII", "expected_pii_categories": ["phone"]},
        ]
        result = eh.metric_pii_redaction(dataset)
        self.assertEqual(result["passed"], 0)
        self.assertEqual(result["failed"], 1)
        self.assertFalse(result["ok"])

    def test_empty_dataset_is_100_percent(self) -> None:
        result = eh.metric_pii_redaction([])
        self.assertEqual(result["passed"], 0)
        self.assertEqual(result["failed"], 0)
        self.assertEqual(result["metric_pct"], 100.0)
        self.assertTrue(result["ok"])

    def test_missing_field_in_sample_is_skipped(self) -> None:
        """Samples with empty text or expected list should not be counted."""
        dataset = [
            {"text": "", "expected_pii_categories": ["phone"]},
            {"text": "phone +7 916 000 00 00", "expected_pii_categories": []},
        ]
        result = eh.metric_pii_redaction(dataset)
        self.assertEqual(result["passed"], 0)
        self.assertEqual(result["failed"], 0)
        self.assertTrue(result["ok"])


class TestCitationMetric(unittest.TestCase):
    """Test that citation_validity behaves correctly."""

    def test_known_clauses_with_correct_quotes_pass(self) -> None:
        # Use a full-shape fixture so the top-level checks also pass.
        fixture = make_fixture(
            enabled=True,
            clauses=[
                {"clause_id": "p.1", "number": "1", "text": "Работник направляется в командировку."},
                {"clause_id": "p.2", "number": "2", "text": "Срок устанавливает работодатель."},
            ],
            requirements=[
                {"field_name": "city", "required": True, "clause_id": "p.1", "quote": "в командировку"},
                {"field_name": "end_date", "required": True, "clause_id": "p.2", "quote": "Срок устанавливает"},
            ],
            citation="PASS",
        )
        result = eh.metric_citation_validity(fixture)
        self.assertEqual(result["failed"], 0)
        self.assertTrue(result["ok"])
        # 4 top-level + 2 requirements = 6
        self.assertGreaterEqual(result["passed"], 6)

    def test_todo_quote_fails(self) -> None:
        fixture = make_fixture(
            enabled=True,
            clauses=[{"clause_id": "p.1", "number": "1", "text": "Работник направляется в командировку."}],
            requirements=[
                {
                    "field_name": "city",
                    "required": True,
                    "clause_id": "p.1",
                    "quote": "TODO: confirm later",
                },
            ],
            citation="NOT_RUN",
        )
        result = eh.metric_citation_validity(fixture)
        # Top-level shape is fine, but the TODO quote causes >=1 failure.
        self.assertGreaterEqual(result["failed"], 1)
        self.assertFalse(result["ok"])

    def test_empty_requirements_still_reports(self) -> None:
        fixture = make_fixture(
            enabled=False,
            clauses=[{"clause_id": "p.1", "number": "1", "text": "Some text."}],
            requirements=[],
        )
        result = eh.metric_citation_validity(fixture)
        # Empty requirements is reported but doesn't error.
        self.assertIsInstance(result["passed"], int)
        self.assertIsInstance(result["failed"], int)


class TestRunEval(unittest.TestCase):
    """Test that run_eval produces a structured report."""

    def test_report_has_all_metric_names(self) -> None:
        report = eh.run_eval()
        names = {m["name"] for m in report["results"]}
        self.assertIn("citation_validity", names)
        self.assertIn("pii_redaction_recall", names)
        self.assertIn("classification_accuracy", names)
        self.assertIn("extraction_recall", names)

    def test_skipped_metrics_include_reason(self) -> None:
        report = eh.run_eval()
        skipped = [m for m in report["results"] if m.get("skipped")]
        self.assertGreaterEqual(len(skipped), 1)
        for s in skipped:
            self.assertIn("reason", s)
            self.assertIsInstance(s["reason"], str)
            self.assertGreater(len(s["reason"]), 0)

    def test_summary_counts_total_pass_fail_skip(self) -> None:
        report = eh.run_eval()
        summary = report["summary"]
        for key in ("total", "passed", "failed", "skipped"):
            self.assertIn(key, summary)
            self.assertIsInstance(summary[key], int)


if __name__ == "__main__":
    unittest.main()
