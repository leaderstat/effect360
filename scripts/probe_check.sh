#!/bin/sh
cat > /tmp/login.json <<'JSON'
{"email":"demo.moderator@example.invalid","password":"demo"}
JSON
TOKEN=$(curl -s -X POST http://api:8000/api/v1/session -H 'Content-Type: application/json' --data-binary @/tmp/login.json | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
echo "=== panel.first_check ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/panel | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d["checks"][0] if d["checks"] else "no checks", indent=2))'
