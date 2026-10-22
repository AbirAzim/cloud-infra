# syntax=docker/dockerfile:1

# ---------- build stage: runs natively on your Mac, cross-compiles to amd64 ----------
  FROM --platform=$BUILDPLATFORM public.ecr.aws/docker/library/golang:1.26-alpine AS build
  ARG TARGETOS TARGETARCH
  ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
  WORKDIR /app
  
  # goose (cross-compiled for the target platform)
  RUN --mount=type=cache,target=/go/pkg/mod \
      --mount=type=cache,target=/root/.cache/go-build \
      go install github.com/pressly/goose/v3/cmd/goose@latest \
      && mkdir -p /out && cp "$(find /go/bin -name goose -type f)" /out/goose
  
  # dependencies (cached unless go.mod/go.sum change)
  COPY go.mod go.sum ./
  RUN --mount=type=cache,target=/go/pkg/mod go mod download
  
  # app
  COPY . .
  RUN --mount=type=cache,target=/go/pkg/mod \
      --mount=type=cache,target=/root/.cache/go-build \
      go build -ldflags="-s -w" -o /out/main .
  
  # ---------- runtime stage: amd64 ----------
  FROM public.ecr.aws/docker/library/alpine:3.21
  
  ENV DOCKERIZE_VERSION=v0.9.3
  RUN apk add --no-cache ca-certificates openssl wget \
      && wget -O - https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-alpine-linux-amd64-$DOCKERIZE_VERSION.tar.gz | tar xzf - -C /usr/local/bin \
      && apk del wget
  
  WORKDIR /app
  COPY --from=build /out/main ./main
  COPY --from=build /out/goose /usr/local/bin/goose
  COPY migrations ./migrations
  COPY static ./static
  COPY templates ./templates
  
  EXPOSE 8080
  CMD ["./main"]