# services/frontend/Dockerfile — Lustre frontend (Gleam + Lustre 5.x).
#
# Stage 0 (styles): Dart Sass 1.77.8 — compiles `styles/theme.sass` and
#                    all of its partials into the single `public/theme.css`.
#                    The Sass version is pinned so the build is reproducible.
# Stage 1 (builder): Erlang/OTP 28 + Gleam 1.19.2 — compiles the
#                    Lustre project to JavaScript with
#                    `gleam build --target javascript`.
# Stage 2 (runtime): nginx:1.27-alpine serving the bundle + index.html
#                    and reverse-proxying /api/ to the Gleam API.
#
# The runtime image contains ONLY the compiled CSS - no Sass compiler, no
# Node.js and no bundler.
#
# This is an INDEPENDENT Gleam project — it does NOT share the API
# service's stdlib constraint. Lustre 5.7.1 resolves gleam_stdlib 1.0.5,
# gleam_json 3.1.0, gleam_erlang 1.3.0, gleam_otp 1.3.0, houdini 1.2.1.
#
# IMPORTANT — the whole `build/dev/javascript/` tree must be copied into
# the runtime image, not just the `effectivnost_360_lustre/` subdirectory.
# The generated ES modules import their dependencies with relative paths
# such as `../../lustre/lustre.mjs` and `../../gleam_stdlib/gleam/dict.mjs`,
# so the dependency directories have to sit next to the app directory.

# -------- Stage 0: styles --------
# Dart Sass is used only at build time. The version is pinned for a
# reproducible build; the runtime image never sees a Sass compiler.
FROM dart-sass/sass:1.77.8 AS styles
WORKDIR /app
COPY styles ./styles
RUN mkdir -p public \
    && sass --no-source-map --style=compressed --load-path=styles \
           styles/theme.sass public/theme.css \
    && test -s public/theme.css

# -------- Stage 1: builder --------
FROM erlang:28-alpine AS builder
ARG GLEAM_VERSION=1.19.2
# SASS_VERSION is pinned so the generated CSS is reproducible.
ARG SASS_VERSION=1.77.8
RUN apk add --no-cache curl tar bash git nodejs npm \
    && curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/gleam-v${GLEAM_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
      | tar -xz -C /usr/local/bin
WORKDIR /app
# Copy only what's needed for compilation to maximise Docker cache.
COPY gleam.toml ./
COPY src ./src
COPY test ./test
COPY styles ./styles
# Fetch all Hex dependencies (Lustre 5.7.1, gleam_stdlib 1.0.5, etc.)
RUN gleam deps download
# Compile the Lustre project to JavaScript. Output goes to
# /app/build/dev/javascript/effectivnost_360_lustre/ by default.
RUN gleam build --target javascript
# Run the unit tests in-container (gleam test compiles to JS too).
RUN gleam test

# -------- Stage 1b: styles --------
# Dart Sass is installed with a pinned version and used ONLY at build time.
# The runtime image receives the finished CSS and never a Sass compiler.
RUN npm install --no-save --no-audit --no-fund "sass@${SASS_VERSION}" \
    && mkdir -p public \
    && npx sass --no-source-map --style=compressed --load-path=styles \
                styles/theme.sass public/theme.css \
    && test -s public/theme.css \
    && rm -rf node_modules package-lock.json

# -------- Stage 2: runtime --------
FROM nginx:1.27-alpine AS runtime
# The complete JS bundle: the app plus every dependency package
# (lustre, gleam_stdlib, gleam_json, ...) that the app imports.
COPY --from=builder /app/build/dev/javascript/ /usr/share/nginx/html/
COPY index.html /usr/share/nginx/html/index.html
COPY --from=builder /app/public/theme.css /usr/share/nginx/html/theme.css
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
