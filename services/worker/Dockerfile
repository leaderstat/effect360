# services/worker/Dockerfile — multi-stage build for Go workers.
#
# Stage 1 (build): golang:1.26-alpine — builds the binary with cache-friendly
#                  layer separation (go.mod → deps → code → binary).
# Stage 2 (runtime): distroless static-debian12:nonroot — minimal runtime,
#                    no shell, no Go toolchain.
#
# Build args:
#   BIN: which binary to compile — `outbox-relay` or `consumer`.
#
# Test target:
#   `docker build --target test services/worker` runs `go test ./...`
#   inside the container. This is the supported way to run the Go tests:
#   the build context is the worker directory, so no bind mount is needed
#   (bind mounts from C:\home are not shared with Docker Desktop on this
#   machine, which silently breaks `docker run -v` based test runners).

# -------- Stage 1: build --------
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
ARG BIN=outbox-relay
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/${BIN} ./cmd/${BIN}

# -------- Stage 1b: test --------
# Same toolchain, runs the unit tests. Kept as a separate stage so the
# production runtime image never carries the Go toolchain.
FROM build AS test
RUN CGO_ENABLED=0 go test -count=1 ./...

# -------- Stage 2: runtime --------
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
ARG BIN=outbox-relay
COPY --from=build /out/${BIN} /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
