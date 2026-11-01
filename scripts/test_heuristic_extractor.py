#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for heuristic_extractor.

Run with:
    python -m unittest scripts.test_heuristic_extractor
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import heuristic_extractor as he  # noqa: E402


class TestHeuristic(unittest.TestCase):
    def test_kazan_full_phrase(self) -> None:
        res = he.classify_and_extract(
            "Прошу учебную поездку в Казань с 12 по 14 ноября 2026 года. "
            "Цель — конференция AI-Summit. Финансирование — грант РФФИ 24-11-001."
        )
        self.assertEqual(res.type, "demo_trip")
        self.assertEqual(res.fields["destination_city"], "Казань")
        self.assertEqual(res.fields["start_date"], "12 ноября")
        self.assertEqual(res.fields["end_date"], "14 ноября")
        self.assertEqual(res.fields["purpose"], "конференция AI-Summit")
        self.assertEqual(res.fields["funding_source"], "grant")
        self.assertEqual(res.fields["grant_number"], "РФФИ 24-11-001")
        self.assertGreaterEqual(res.confidence, 0.7)

    def test_no_trip_keyword_is_other(self) -> None:
        res = he.classify_and_extract("Это просто тест.")
        self.assertEqual(res.type, "other")
        self.assertEqual(res.confidence, 0.9)

    def test_budget_trip(self) -> None:
        res = he.classify_and_extract(
            "Нужно поехать в Санкт-Петербург 3-5 декабря, встречи с подрядчиками. "
            "Оплата из бюджета отдела."
        )
        self.assertEqual(res.type, "demo_trip")
        self.assertEqual(res.fields["destination_city"], "Санкт-Петербург")
        self.assertEqual(res.fields["funding_source"], "budget")
        self.assertNotIn("grant_number", res.fields)

    def test_empty_input(self) -> None:
        res = he.classify_and_extract("")
        self.assertEqual(res.type, "other")
        self.assertEqual(res.confidence, 0.0)

    def test_dash_range_dates(self) -> None:
        res = he.classify_and_extract(
            "Прошу командировку в Сочи 1-7 марта."
        )
        self.assertEqual(res.fields["start_date"], "1 марта")
        self.assertEqual(res.fields["end_date"], "7 марта")

    def test_only_keyword_no_fields(self) -> None:
        res = he.classify_and_extract("Прошу поездку.")
        self.assertEqual(res.type, "demo_trip")
        self.assertLess(res.confidence, 0.7)


if __name__ == "__main__":
    unittest.main(verbosity=2)
