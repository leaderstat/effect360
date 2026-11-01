# tooling/Dockerfile — multi-purpose toolchain container for QA, citation
# validation, Playwright E2E, and ad-hoc tooling. Not used as a runtime
# service; consumed via `docker compose run --rm tooling ...` and via the
# `qa` profile (`docker compose --profile qa run --rm qa ...`).
#
# Targets:
#   - Python 3.12 (citation validator, eval harness, live eval)
#   - Node.js 20 (frontend syntax check, qa_e2e.mjs)
#   - Playwright (Chromium + dependencies) for browser automation
#   - curl, jq, bash for diagnostics
#
# This image deliberately does NOT contain Gleam/Erlang/Go — those live
# in their respective service build stages. This image also avoids the
# postgres client (psql) to keep it small; db access goes through the
# API service or psql container.

FROM mcr.microsoft.com/playwright:v1.49.1-jammy AS base

# System packages required by Playwright Chromium on Linux.
#
# NOTE: mcr.microsoft.com/playwright:v1.49.1-jammy is Ubuntu 22.04 (jammy).
# Its python3 is 3.10, NOT 3.12 — the previous `update-alternatives
# --install /usr/bin/python python /usr/bin/python3.12` line failed the
# build with "alternative path /usr/bin/python3.12 doesn't exist".
# We use the interpreter that is actually present in the base image
# (python3 -> python3.10) instead of forcing a version that is not there.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl jq bash ca-certificates \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Make the base image's python3 available as `python`.
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1 \
    && python -m pip install --no-cache-dir --upgrade pip

# Project-local Python deps (kept minimal: pytest for unit tests).
# Build context for this image is ./tooling (see compose.yaml), so
# requirements.txt is at the root of the build context.
WORKDIR /tooling
COPY requirements.txt /tooling/requirements.txt
RUN python -m pip install --no-cache-dir -r /tooling/requirements.txt

# qa_e2e.mjs lives in scripts/ — tooling image does NOT bake them in;
# the PowerShell scripts always bind-mount the project root at /work.
WORKDIR /work

ENV NODE_PATH=/usr/lib/node_modules \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Default CWD inside tooling — the calling PowerShell scripts will
# bind-mount /work as needed.
CMD ["bash"]
