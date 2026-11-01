#!/bin/sh
# Sync the frontend sources into the long-lived builder container and run
# the given Gleam command. Usage: sh sync-and-run.sh "gleam test"
set -e
SRC=/work/frontend
DST=/app
# Copy everything except the build output and the dependency cache.
rm -rf "$DST/src" "$DST/test"
cp -r "$SRC/src" "$DST/src"
cp -r "$SRC/test" "$DST/test"
cp "$SRC/gleam.toml" "$DST/gleam.toml"
cp "$SRC/gleam.lock" "$DST/gleam.lock" 2>/dev/null || true
cd "$DST"
sh -c "$1"
