#!/usr/bin/env python3
"""
backend-stub.py — a minimal HTTP server that mimics the three endpoints
the Lustre frontend actually calls. It is *only* a tool for the E2E
screenshot run — it is NOT a replacement for the real Gleam API.

Behaviour mirrors the contract documented in
services/api/src/effectivnost_360/router.gleam:
  POST /api/v1/requests                 -> 202 {request_id}
  GET  /api/v1/requests/{id}            -> 200 {id,status,request_type,fields,...}
  POST /api/v1/requests/{id}/submit     -> 422 missing[]   (first call)
                                         200 {status:"submitted"} (second call)
                                         409 {error:"invalid_status",...}
"""

import json, uuid, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

# Each request id -> dict with status, fields, etc.
state = {}
state_lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        # Same-origin so we don't need CORS, but nginx adds it for the
        # /api/ proxy anyway.
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        # Quieter logs.
        pass

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8") if length else "{}"
        return json.loads(body or "{}")

    def do_POST(self):
        with state_lock:
            if self.path == "/api/v1/requests":
                req = self._read_json()
                text = (req.get("text") or "").strip()
                req_id = "demo-" + uuid.uuid4().hex[:12]
                # Auto-extract a few obvious fields from the free text so
                # the UI's "Поля заявки" block is populated immediately.
                fields = {}
                if text:
                    import re
                    m_city = re.search(r"в\s+([А-ЯЁ][а-яё\-]+)", text)
                    if m_city:
                        fields["destination_city"] = m_city.group(1)
                    m_dates = re.search(r"(\d{1,2})[–\-](\d{1,2})\s+([а-яё]+)", text)
                    if m_dates:
                        months = {
                            "января":"01","февраля":"02","марта":"03","апреля":"04",
                            "мая":"05","июня":"06","июля":"07","августа":"08",
                            "сентября":"09","октября":"10","ноября":"11","декабря":"12",
                        }
                        month = months.get(m_dates.group(3).lower(), "01")
                        fields["start_date"] = f"2026-{month}-{int(m_dates.group(1)):02d}"
                        fields["end_date"]   = f"2026-{month}-{int(m_dates.group(2)):02d}"
                    if "грант" in text.lower():
                        fields["funding_source"] = "grant"
                        m_grant = re.search(r"(рсф|рнф|рфф|rff|RSF|grant)\-?\d+", text, re.I)
                        if m_grant:
                            fields["grant_number"] = m_grant.group(0)
                    else:
                        fields["funding_source"] = "budget"
                    if "конференц" in text.lower():
                        fields["purpose"] = "конференция"
                state[req_id] = {
                    "id": req_id,
                    "status": "draft",
                    "request_type": "demo_trip",
                    "fields": fields,
                    "submitted_at": "",
                    "created_at": "2026-10-23T10:00:00Z",
                    "submitted_count": 0,
                }
                return self._send(202, {"request_id": req_id, "created": True})

            # PATCH-style endpoint used by the E2E only. The real backend
            # will have a PATCH endpoint in v0.2 (see cjm-screen-map §8).
            # The UI itself does not call it — values are local-only today.
            if "/fields" in self.path and self.path.startswith("/api/v1/requests/"):
                req_id = self.path.split("/")[4]
                rec = state.get(req_id)
                if rec is None:
                    return self._send(404, {"error": "request_not_found"})
                rec["fields"].update(self._read_json().get("fields", {}))
                return self._send(200, {"fields": rec["fields"]})

            if self.path.endswith("/submit"):
                req_id = self.path.rsplit("/", 2)[-2]
                rec = state.get(req_id)
                if rec is None:
                    return self._send(404, {"error": "request_not_found"})
                rec["submitted_count"] += 1
                if rec["status"] == "submitted":
                    return self._send(409, {
                        "error": "invalid_status",
                        "message": "only draft requests can be submitted",
                        "current_status": "submitted",
                    })
                # First submit -> always incomplete, so the UI exercises
                # the 422 -> missing[] path with real citations.
                missing = []
                required = [
                    "destination_city","purpose","start_date","end_date",
                    "funding_source","approver_id",
                ]
                for f in required:
                    if not rec["fields"].get(f):
                        missing.append({
                            "field_name": f,
                            "required": True,
                            "conditional": False,
                            "reason": "требуется по положению",
                            "clause_id": "demo-1." + str(required.index(f)+1),
                            "quote": "В заявке должны быть указаны: " + f + ".",
                        })
                if rec["fields"].get("funding_source") == "grant" and not rec["fields"].get("grant_number"):
                    missing.append({
                        "field_name": "grant_number",
                        "required": True,
                        "conditional": True,
                        "reason": "при грантовом финансировании нужен номер гранта",
                        "clause_id": "demo-2.3",
                        "quote": "При финансировании за счёт гранта указывается номер гранта.",
                    })
                if missing:
                    return self._send(422, {"complete": False, "missing": missing})
                rec["status"] = "submitted"
                rec["submitted_at"] = "2026-10-23T10:00:00Z"
                return self._send(200, {
                    "status": "submitted",
                    "submitted_at": rec["submitted_at"],
                })

            return self._send(404, {"error": "not_found"})

    def do_GET(self):
        with state_lock:
            if self.path.startswith("/api/v1/requests/"):
                req_id = self.path.rsplit("/", 1)[-1]
                rec = state.get(req_id)
                if rec is None:
                    return self._send(404, {"error": "request_not_found"})
                return self._send(200, {
                    "id": rec["id"],
                    "status": rec["status"],
                    "request_type": rec["request_type"],
                    "fields": rec["fields"],
                    "submitted_at": rec["submitted_at"],
                    "created_at": rec["created_at"],
                })
            return self._send(404, {"error": "not_found"})

if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
