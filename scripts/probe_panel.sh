#!/bin/sh
TOKEN=$(curl -s -X POST "http://172.23.0.7:8000/api/v1/session" \
  -H "Content-Type: application/json" \
  --data-binary '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://172.23.0.7:8000/api/v1/automation/panel" > /tmp/panel.json
echo "=== TOP KEYS ==="
node -e 'const j=require("/tmp/panel.json"); console.log(Object.keys(j).join(","))'
echo "=== FIRST CHECK KEYS ==="
node -e 'const j=require("/tmp/panel.json"); console.log(Object.keys(j.checks[0]||{}).join(","))'
echo "=== FIRST CHECK JSON ==="
node -e 'const j=require("/tmp/panel.json"); console.log(JSON.stringify(j.checks[0]||{}, null, 2).slice(0, 1200))'
