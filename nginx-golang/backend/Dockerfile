# syntax=docker/dockerfile:1.4
# ^ BuildKit syntax directive. Must be the first line of the file so
# BuildKit picks it up (any comment above it disables the directive).
# Selects the Dockerfile frontend version and enables features used
# below such as RUN --mount and heredocs.
# https://docs.docker.com/build/buildkit/frontend/

# --------------------------------------------------------------------
# Stage 1: builder — compiles the Go binary.
# `--platform=$BUILDPLATFORM` pins this stage to the build host's
# architecture so cross-arch builds don't emulate the compile step
# (much faster). For a true multi-arch binary, also pass TARGETOS /
# TARGETARCH into `go build`.
# https://docs.docker.com/build/building/multi-platform/
# --------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.18-alpine AS builder

# All following instructions run in /code inside the image.
WORKDIR /code

# CGO_ENABLED=0 produces a fully static binary with no libc dependency,
# which is what allows the final `scratch` stage to run it.
ENV CGO_ENABLED 0
# Explicit Go module + build cache paths so the RUN --mount cache
# targets below match Go's actual cache locations.
ENV GOPATH /go
ENV GOCACHE /go-build

# Copy manifests first so `go mod download` can be cached independently
# from the source. This layer only rebuilds when go.mod / go.sum change.
COPY go.mod go.sum ./
# BuildKit cache mount: persists Go's module cache across builds
# without baking it into an image layer.
# https://docs.docker.com/reference/dockerfile/#run---mounttypecache
RUN --mount=type=cache,target=/go/pkg/mod/cache \
    go mod download

# Now copy the rest of the source tree.
COPY . .

# Build with two cache mounts: the shared module cache and Go's build
# cache. Both persist across builds via BuildKit, not in image layers.
RUN --mount=type=cache,target=/go/pkg/mod/cache \
    --mount=type=cache,target=/go-build \
    go build -o bin/backend main.go

# Default command when this stage is used directly (compose.yaml runs
# `target: builder`, so this is what actually starts in `docker compose up`).
CMD ["/code/bin/backend"]

# --------------------------------------------------------------------
# Stage 2: dev-envs — legacy stage from Docker's Dev Environments
# feature (removed from this repo). Not built by compose.yaml and safe
# to delete if you don't use Dev Environments tooling.
# --------------------------------------------------------------------
FROM builder as dev-envs

# Install git so IDE / Dev Environments tooling can operate on the
# workspace inside the container.
RUN <<EOF
apk update
apk add git
EOF

# Create an unprivileged `vscode` user in a `docker` group, matching
# the convention expected by the Dev Environments container tooling.
RUN <<EOF
addgroup -S docker
adduser -S --shell /bin/bash --ingroup docker vscode
EOF

# Third-party helper image that bundles the Docker CLI, buildx, and
# compose so a dev container can run `docker` commands against the
# host socket. Note: not an official Docker image.
COPY --from=gloursdocker/docker / /

# In dev, run straight from source with `go run` (no prebuilt binary).
CMD ["go", "run", "main.go"]

# --------------------------------------------------------------------
# Stage 3: final production image — minimal `scratch` base with just
# the compiled binary. No shell, no libc, no package manager, so the
# attack surface is close to zero. Requires the static binary produced
# above (CGO_ENABLED=0).
# https://docs.docker.com/build/building/multi-stage/
# --------------------------------------------------------------------
FROM scratch
COPY --from=builder /code/bin/backend /usr/local/bin/backend
CMD ["/usr/local/bin/backend"]
