#!/bin/sh
sh /tmp/pl.sh > /tmp/login.txt
TOK=$(grep -o '"token":"[^"]*' /tmp/login.txt | cut -d'"' -f4)
echo "TOK_LEN=${#TOK}"
node /tmp/pc.mjs "$TOK"
