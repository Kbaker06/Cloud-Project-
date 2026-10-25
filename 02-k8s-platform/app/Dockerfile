# syntax=docker/dockerfile:1.7
# Multi-stage, multi-arch build. Final image: ~18 MB, no shell, no package manager, runs as UID 65532.
#   docker buildx build --platform linux/amd64,linux/arm64 -t pulse-api:dev .

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS build
WORKDIR /src

# Dependencies first so this layer is cached until go.mod/go.sum change.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
ARG TARGETOS TARGETARCH
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/pulse-api ./cmd/pulse-api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/pulse-api /pulse-api
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/pulse-api"]
