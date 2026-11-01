#!/bin/sh
set -e
TOKEN=$(curl -s -X POST http://api:8000/api/v1/session \
  -H "Content-Type: application/json" \
  -d '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
echo "TOKEN_LEN=${#TOKEN}"
node /tmp/pb.mjs "$TOKEN"
