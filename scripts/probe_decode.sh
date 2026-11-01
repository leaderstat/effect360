#!/bin/sh
TOKEN=$(curl -s -X POST http://api:8000/api/v1/session \
  -H "Content-Type: application/json" \
  -d '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')

echo "=== panel keys ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/panel \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sorted(d.keys()))'
echo "=== panel first exception ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/panel \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d["exceptions"][0] if d["exceptions"] else {}, indent=2))'
echo "=== panel metric example ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/panel \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d["metrics"][0] if d["metrics"] else "no metrics", indent=2))'
