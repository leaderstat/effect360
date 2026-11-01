#!/bin/sh
sed -i 's|http://172.23.0.7:8000|http://api:8000|g' /root/shots_v2.mjs
sed -i 's|ctx.request.post|fetch|g' /root/shots_v2.mjs
rm -f /tmp/shots_v2/*.png
node /root/shots_v2.mjs
