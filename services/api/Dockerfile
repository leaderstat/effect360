# services/api/Dockerfile — multi-stage build for the Effectivnost 360 API.
#
# Stage 1 (build): Erlang/OTP 28 + Gleam 1.19.2 — compiles the project AND
#                  runs `gleam test` (used by `make test-gleam` from the host).
# Stage 2 (runtime): minimal Erlang runtime with the compiled artefacts.
#                    No Gleam compiler, no source tree — only build/ + vendor/.
#
# IMPORTANT: `gleam test` runs in Stage 1. If any unit test fails the build
# of the `runtime` stage is skipped — that's a feature, not a bug.

# -------- Stage 1: build + test --------
FROM erlang:28-alpine AS build
ARG GLEAM_VERSION=1.19.2
RUN apk add --no-cache curl tar bash \
  && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
  | tar -xz -C /usr/local/bin
WORKDIR /app
# Copy only what's needed for compilation/test to maximise Docker cache.
COPY gleam.toml manifest.toml ./
COPY vendor ./vendor
RUN gleam deps download
COPY src ./src
COPY test ./test
# Compile and run the unit tests. `gleam test` exits non-zero on failure.
RUN gleam check \
  && gleam test \
  && gleam build

# -------- Stage 2: runtime --------
# Minimal Erlang runtime. No Gleam compiler, no source tree, no Node.js.
# Starts the OTP application from the already-compiled BEAM artefacts.
FROM erlang:28-alpine AS runtime
WORKDIR /app
COPY --from=build /app/build /app/build
COPY --from=build /app/manifest.toml /app/manifest.toml
COPY --from=build /app/vendor /app/vendor
COPY --from=build /app/gleam.toml /app/gleam.toml
ENV PORT=8000
EXPOSE 8000
# Start the compiled OTP application directly. Gleam's `pub fn main()` is
# compiled to `effectivnost_360_api:main/0` — NOT `start/0`. The project
# has no .app callback module, so `-s application start` would be a no-op.
CMD ["sh", "-c", "exec erl -noshell -noinput -pa /app/build/dev/erlang/effectivnost_360_api/ebin -pa /app/build/dev/erlang/*/ebin -s effectivnost_360_api main"]
