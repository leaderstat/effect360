#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Pure-Python implementation of the deterministic classifier + field
extractor used by the eval harness and by the consumer's fallback path.

Mirrors `services/worker/internal/extractor/heuristic.go`. The two
implementations MUST stay semantically identical: the eval harness
should produce the same numbers on the same dataset regardless of
which one runs, so that the heuristic baseline is stable.

This module has no third-party dependencies and is safe to import in
unit tests.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any


# Russian cities used by the demo. Intentionally conservative: false
# negatives are acceptable here because the real LLM is expected to
# do better. The list mirrors the Go implementation.
_CITIES = (
    "Казань", "Москва", "Санкт-Петербург", "Новосибирск", "Сочи",
    "Екатеринбург", "Нижний Новгород", "Самара", "Калининград",
    "Владивосток", "Краснодар", "Уфа", "Челябинск", "Ростов-на-Дону",
)

_MONTHS = {
    "января": "января", "январь": "января",
    "февраля": "февраля", "февраль": "февраля",
    "марта": "марта", "март": "марта",
    "апреля": "апреля", "апрель": "апреля",
    "мая": "мая", "май": "мая",
    "июня": "июня", "июнь": "июня",
    "июля": "июля", "июль": "июля",
    "августа": "августа", "август": "августа",
    "сентября": "сентября", "сентябрь": "сентября",
    "октября": "октября", "октябрь": "октября",
    "ноября": "ноября", "ноябрь": "ноября",
    "декабря": "декабря", "декабрь": "декабря",
}

_TRIP_KEYWORDS = re.compile(r"(командировк|поездк|учебн|поехат|поезд)", re.IGNORECASE)
_DATE_RANGE_DASH = re.compile(r"(\d{1,2})\s*[-—–]\s*(\d{1,2})\s+([а-яё]+)", re.IGNORECASE)
_DATE_RANGE_PO = re.compile(r"(?:с\s+)?(\d{1,2})\s+по\s+(\d{1,2})\s+([а-яё]+)", re.IGNORECASE)
_PURPOSE = re.compile(r"цель\s*[—\-:]\s*([^.,;]{3,80})", re.IGNORECASE)
_GRANT_NUMBER = re.compile(r"([А-ЯЁA-Z]{2,6}\s*\d{2}-\d{2}-\d{3})")


@dataclass
class Extracted:
    type: str
    fields: dict[str, str] = field(default_factory=dict)
    confidence: float = 0.0
    reason: str = ""


def classify_and_extract(text: str) -> Extracted:
    """Run the heuristic classifier + extractor on the free-form text.

    Returns Extracted with `type` in {"demo_trip", "other"} and a
    confidence in [0,1] used by the consumer to decide between
    succeeded and manual_review.
    """
    text = (text or "").strip()
    if not text:
        return Extracted(type="other", confidence=0.0, reason="empty text")

    lower = text.lower()
    if not _TRIP_KEYWORDS.search(text):
        return Extracted(type="other", confidence=0.9, reason="no trip keyword")

    fields: dict[str, str] = {}

    # Destination city.
    for city in _CITIES:
        if city in text:
            fields["destination_city"] = city
            break

    # Date range.
    m = _DATE_RANGE_DASH.search(text)
    if m:
        month = _MONTHS.get(m.group(3).lower(), m.group(3))
        fields["start_date"] = f"{m.group(1)} {month}"
        fields["end_date"] = f"{m.group(2)} {month}"
    else:
        m = _DATE_RANGE_PO.search(text)
        if m:
            month = _MONTHS.get(m.group(3).lower(), m.group(3))
            fields["start_date"] = f"{m.group(1)} {month}"
            fields["end_date"] = f"{m.group(2)} {month}"

    # Purpose.
    m = _PURPOSE.search(text)
    if m:
        fields["purpose"] = m.group(1).strip()

    # Funding + grant number.
    if "грант" in lower:
        fields["funding_source"] = "grant"
        m = _GRANT_NUMBER.search(text)
        if m:
            fields["grant_number"] = m.group(1).strip()
    elif "бюджет" in lower or "оплата из" in lower:
        fields["funding_source"] = "budget"

    hits = sum(1 for k in ("destination_city", "start_date", "purpose", "funding_source") if fields.get(k))
    if hits >= 2:
        confidence = 0.9
        reason = "trip with structured fields"
    elif hits == 1:
        confidence = 0.6
        reason = "trip with one structured field"
    else:
        confidence = 0.3
        reason = "trip without structured fields"

    return Extracted(type="demo_trip", fields=fields, confidence=confidence, reason=reason)


# -- adapter callables for the eval harness ------------------------------

def classify_fn(text: str) -> str:
    """Adapter for `metric_classification_accuracy(classify_fn=...)`."""
    return classify_and_extract(text).type


def extract_fn(text: str) -> dict[str, Any]:
    """Adapter for `metric_extraction_recall(extract_fn=...)`.

    Note: returns a plain dict so the harness can use
    `.get(k) is not None and == v` as a key-presence + value-equality
    check.
    """
    res = classify_and_extract(text)
    return res.fields
