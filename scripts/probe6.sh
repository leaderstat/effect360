#!/bin/sh
TOKEN=$(curl -s -X POST "http://172.23.0.7:8000/api/v1/session" \
  -H "Content-Type: application/json" \
  --data-binary '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
for ep in "agent/events" "agent/notifications" "automation/exceptions?only_open=true"; do
  echo "=== $ep ==="
  curl -s -H "Authorization: Bearer $TOKEN" "http://172.23.0.7:8000/api/v1/automation/$ep" | head -c 500
  echo ""
done
