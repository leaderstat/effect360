#!/bin/sh
TOKEN=$(curl -s -X POST "http://172.23.0.7:8000/api/v1/session" \
  -H "Content-Type: application/json" \
  --data-binary '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "=== AGENT/METRICS ==="
curl -s -H "Authorization: Bearer $TOKEN" "http://172.23.0.7:8000/api/v1/automation/agent/metrics" | head -c 800
echo ""
echo "=== AGENT/CHECKS ==="
curl -s -H "Authorization: Bearer $TOKEN" "http://172.23.0.7:8000/api/v1/automation/agent/checks" | head -c 800
