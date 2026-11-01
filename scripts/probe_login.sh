#!/bin/sh
cat > /tmp/login.json <<'JSON'
{"email":"demo.moderator@example.invalid","password":"demo"}
JSON
echo "=== POST login ==="
curl -s -X POST http://api:8000/api/v1/session -H 'Content-Type: application/json' --data-binary @/tmp/login.json
echo ""
